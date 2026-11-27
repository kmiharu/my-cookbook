package cookbook.batch.examples.dynamo;

import cookbook.batch.dynamodb.DynamoClients;
import cookbook.batch.dynamodb.DynamoCustomer;
import cookbook.batch.dynamodb.DynamoMutation;
import cookbook.batch.dynamodb.DynamoRepository;
import cookbook.batch.examples.JobFiles;
import cookbook.batch.examples.RunContext;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

final class DynamoDelivery {
    static final List<String> REPORT_COLUMNS = List.of("job", "run_id", "state", "rows");

    private static final Logger log = LoggerFactory.getLogger(DynamoDelivery.class);

    private final RunContext context;
    private final JobFiles files;
    private final DynamoMapper mapper;
    private final DynamoSettings settings;
    private final Environment environment;
    private final TransactionTemplate transactions;
    private final DynamoWork work;

    DynamoDelivery(RunContext context, JobFiles files, DynamoMapper mapper, DynamoSettings settings,
                   Environment environment, PlatformTransactionManager transactionManager, DynamoWork work) {
        this.context = context;
        this.files = files;
        this.mapper = mapper;
        this.settings = settings;
        this.environment = environment;
        this.transactions = new TransactionTemplate(transactionManager);
        this.work = work;
    }

    private String runKey() {
        return context.job() + ":" + context.runId();
    }

    private DynamoPlan plan() {
        return DynamoPlan.from(context, settings);
    }

    void deliverPg() throws Exception {
        var plan = plan();
        var mode = plan.deliversOutbox() ? Mode.OUTBOX : Mode.MUTATIONS;
        deliver(plan, mode, plan.read().partition());
    }

    void deliverInput() throws Exception {
        var plan = plan();
        var mode = plan.replacesGeneration() ? Mode.REPLACE_GENERATION : Mode.MUTATIONS;
        deliver(plan, mode, plan.read().partition());
    }

    void benchmarkWrite() throws Exception {
        var plan = plan();
        if (plan.targetPartition() != null) {
            deliver(plan, Mode.REPLACE_GENERATION, plan.targetPartition());
        }
    }

    void writeReport() throws Exception {
        files.export("delivery", true, REPORT_COLUMNS.toArray(String[]::new), sink -> {
            var state = mapper.state(runKey());
            if (!"APPLIED".equals(state.state())) {
                throw new IllegalStateException("DynamoDB work has not been applied");
            }
            long delivered = plan().deliversOutbox()
                    ? mapper.countOutbox(runKey()) : mapper.countWork(runKey());
            sink.row(List.of(context.job(), context.runId(), "APPLIED", Long.toString(delivered)));
        });
    }

    private void deliver(DynamoPlan plan, Mode mode, String target) throws Exception {
        var state = mapper.state(runKey());
        if ("APPLIED".equals(state.state())) {
            return;
        }
        if (!"READY".equals(state.state())) {
            throw new IllegalStateException("DynamoDB work is not READY");
        }
        var metrics = new DynamoClients.Metrics();
        try (var client = settings.openClient(environment.matchesProfiles("local"), metrics)) {
            var repo = settings.repository(client, plan);
            if (mode == Mode.REPLACE_GENERATION) {
                claimGeneration(repo, target);
            } else {
                work.requireMutableGeneration(target);
            }
            var workers = Executors.newFixedThreadPool(plan.workers());
            try {
                deliverGroups(repo, plan, workers, mode, target);
            } finally {
                workers.shutdownNow();
                workers.close();
            }
            recordCompletion(mode, target);
            log.info("DynamoDB delivery job={} runId={} batchSize={} workers={} metrics={} {}",
                    context.job(), context.runId(), plan.batchSize(), plan.workers(), repo.metrics(), metrics);
        }
    }

    private void recordCompletion(Mode mode, String target) {
        transactions.executeWithoutResult(status -> {
            if (mode == Mode.OUTBOX) {
                if (mapper.undeliveredOutbox(runKey()) != 0) {
                    throw new IllegalStateException("An earlier outbox version is pending; resume the earlier run first");
                }
                if (mapper.markApplied(runKey()) != 1) {
                    throw new IllegalStateException("DynamoDB outbox completion could not be recorded");
                }
            } else if (mapper.applied(runKey()) != 1) {
                throw new IllegalStateException("DynamoDB completion could not be recorded");
            }
            if (mode == Mode.REPLACE_GENERATION && mapper.markGenerationDelivered(target, runKey()) != 1) {
                throw new IllegalStateException("DynamoDB generation completion could not be recorded");
            }
        });
    }

    private void deliverGroups(DynamoRepository repo, DynamoPlan plan,
                               ExecutorService workers, Mode mode, String target) throws Exception {
        int groupSize = mode == Mode.REPLACE_GENERATION ? plan.batchSize() : 1;
        int limit = Math.multiplyExact(groupSize, plan.workers());
        for (;;) {
            context.checkStop();
            var pending = mode == Mode.OUTBOX ? mapper.nextOutbox(runKey(), limit) : mapper.pending(runKey(), limit);
            if (pending.isEmpty()) {
                return;
            }
            // Fetch and submit one window only. Acknowledge successful groups before throwing a failure.
            var outstanding = new ArrayList<PendingWrite>(plan.workers());
            for (int start = 0; start < pending.size(); start += groupSize) {
                int end = Math.min(start + groupSize, pending.size());
                var rows = List.copyOf(pending.subList(start, end));
                var result = workers.submit(() -> {
                    writeGroup(repo, plan, mode, target, rows);
                    return null;
                });
                outstanding.add(new PendingWrite(rows, result));
            }

            Exception deliveryFailure = null;
            var successful = new ArrayList<DynamoMapper.Work>(pending.size());
            for (var write : outstanding) {
                try {
                    write.result().get();
                    successful.addAll(write.rows());
                } catch (ExecutionException failure) {
                    if (deliveryFailure == null) {
                        deliveryFailure = new IllegalStateException("DynamoDB delivery failed", failure.getCause());
                    } else {
                        deliveryFailure.addSuppressed(failure.getCause());
                    }
                }
            }
            if (!successful.isEmpty()) {
                acknowledge(mode, successful);
            }
            if (deliveryFailure != null) {
                throw deliveryFailure;
            }
        }
    }

    private void writeGroup(DynamoRepository repo, DynamoPlan plan, Mode mode, String target,
                            List<DynamoMapper.Work> rows) throws InterruptedException {
        context.checkStop();
        if (mode == Mode.REPLACE_GENERATION) {
            var customers = rows.stream()
                    .map(row -> customer(row, new DynamoCustomer.Key(target, row.sk()), row.version()))
                    .toList();
            repo.replaceGenerationBatch(customers);
        } else {
            repo.mutate(mutation(rows.getFirst(), plan, mode));
        }
    }

    private void acknowledge(Mode mode, List<DynamoMapper.Work> successful) {
        failAfterDynamoWriteForTest();
        transactions.executeWithoutResult(status -> {
            int count = mode == Mode.OUTBOX
                    ? mapper.outboxDelivered(runKey(), successful)
                    : mapper.delivered(runKey(), successful);
            if (count != successful.size()) {
                throw new IllegalStateException("DynamoDB delivery acknowledgement changed");
            }
        });
    }

    private void failAfterDynamoWriteForTest() {
        if (environment.matchesProfiles("local & fault-test")
                && "AFTER_DYNAMO_WRITE".equals(environment.getProperty("BATCH_FAULT_PHASE"))) {
            if ("halt".equals(environment.getProperty("BATCH_FAULT_ACTION"))) {
                Runtime.getRuntime().halt(93);
            }
            throw new IllegalStateException("Test failure after DynamoDB success before PostgreSQL acknowledgement");
        }
    }

    private void claimGeneration(DynamoRepository repo, String target) throws InterruptedException {
        String owner = mapper.generationOwner(target);
        if (owner == null) {
            var read = new DynamoRepository.Read(DynamoRepository.ReadMode.QUERY, target, false, null, true, 1);
            if (!repo.page(read, Map.of()).items().isEmpty()) {
                throw new IllegalArgumentException("BatchWrite requires a new dedicated generation");
            }
        }
        if (!runKey().equals(transactions.execute(tx -> mapper.claimGeneration(target, runKey())))) {
            throw new IllegalStateException("DynamoDB generation is owned by another run");
        }
    }

    private DynamoMutation mutation(DynamoMapper.Work row, DynamoPlan plan, Mode mode) {
        var key = new DynamoCustomer.Key(row.pk(), row.sk());
        if (mode == Mode.OUTBOX) {
            String operation = DynamoWork.identityHash("outbox", row.pk(), row.sk(), Long.toString(row.version()));
            return new DynamoMutation(operation, DynamoMutation.Kind.STATUS, key, row.version() - 1,
                    customer(row, key, row.version()), null);
        }
        String operation = DynamoWork.identityHash(runKey(), row.pk(), row.sk());
        return switch (context.job()) {
            case "DynamoDbDelete" -> new DynamoMutation(operation, DynamoMutation.Kind.DELETE, key,
                    row.version(), null, null);
            case "DynamoDbConditionalUpdate" -> plan.operation().equals("add")
                    ? new DynamoMutation(operation, DynamoMutation.Kind.ADD, key, row.version(), null, row.balance())
                    : new DynamoMutation(operation, DynamoMutation.Kind.UPDATE, key, row.version(),
                            customer(row, key, Math.incrementExact(row.version())), null);
            default -> new DynamoMutation(operation, DynamoMutation.Kind.INSERT_ONLY, key, -1,
                    customer(row, key, row.version()), null);
        };
    }

    private static DynamoCustomer customer(DynamoMapper.Work row, DynamoCustomer.Key key, long version) {
        return new DynamoCustomer(key, version, row.status(), row.balance(),
                DynamoInputReader.memo(row.memoState(), row.memo()));
    }

    private enum Mode { MUTATIONS, OUTBOX, REPLACE_GENERATION }

    private record PendingWrite(List<DynamoMapper.Work> rows, Future<?> result) { }
}
