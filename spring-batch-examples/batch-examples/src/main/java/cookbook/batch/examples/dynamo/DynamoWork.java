package cookbook.batch.examples.dynamo;

import cookbook.batch.dynamodb.DynamoClients;
import cookbook.batch.dynamodb.DynamoCustomer;
import cookbook.batch.dynamodb.PageKey;
import cookbook.batch.examples.JobFiles;
import cookbook.batch.examples.RunContext;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.ZoneOffset;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;
import java.util.function.ToIntFunction;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

final class DynamoWork {
    private static final Logger log = LoggerFactory.getLogger(DynamoWork.class);
    private static final int INSERT_ROWS = 1_000;

    private final RunContext context;
    private final JobFiles files;
    private final DynamoMapper mapper;
    private final DynamoSettings settings;
    private final Environment environment;
    private final TransactionTemplate transactions;
    private final TransactionTemplate readOnly;

    DynamoWork(RunContext context, JobFiles files, DynamoMapper mapper, DynamoSettings settings,
               Environment environment, PlatformTransactionManager transactionManager) {
        this.context = context;
        this.files = files;
        this.mapper = mapper;
        this.settings = settings;
        this.environment = environment;
        this.transactions = new TransactionTemplate(transactionManager);
        this.readOnly = new TransactionTemplate(transactionManager);
        this.readOnly.setReadOnly(true);
    }

    DynamoInputReader inputReader() {
        return new DynamoInputReader(context, files, mapper, runKey(), settings);
    }

    private String runKey() {
        return context.job() + ":" + context.runId();
    }

    private DynamoPlan plan() {
        return DynamoPlan.from(context, settings);
    }

    void startInput() {
        if (files.pinList().size() != 1) {
            throw new IllegalArgumentException("A DynamoDB input job requires one file");
        }
        transactions.executeWithoutResult(status -> mapper.start(runKey()));
    }

    void stageInputRows(List<? extends DynamoMapper.Work> rows) {
        insertBatches(rows, mapper::stage);
    }

    void sealInput() {
        DynamoPlan plan = plan();
        var version = files.pinList().getFirst();
        String sourceVersion = version.versionId() == null ? version.eTag() : version.versionId();
        String revision = identityHash(version.bucket(), version.key(), sourceVersion);
        transactions.executeWithoutResult(status -> {
            var state = mapper.state(runKey());
            if (state.inputRows() == null || state.inputRows() != files.expectedRows(0)
                    || !files.expectedSha(0).equals(state.inputSha256())) {
                throw new IllegalStateException("Input has not reached verified EOF");
            }
            String owner = mapper.claimInput(context.job(), revision, plan.read().partition(), runKey());
            if (!runKey().equals(owner)) {
                throw new IllegalStateException("Input revision is already assigned to another run");
            }
            if ("PREPARING".equals(state.state()) && mapper.seal(runKey()) != 1) {
                throw new IllegalStateException("DynamoDB input work could not be marked READY");
            }
        });
    }

    void stageDynamoSnapshot() throws Exception {
        var plan = plan();
        transactions.executeWithoutResult(status -> mapper.start(runKey()));
        var state = mapper.state(runKey());
        if (!"PREPARING".equals(state.state())) {
            return;
        }
        var metrics = new DynamoClients.Metrics();
        try (var client = settings.openClient(environment.matchesProfiles("local"), metrics)) {
            var repo = settings.repository(client, plan);
            var checkpoint = PageKey.decode(state.nextPage());
            for (;;) {
                context.checkStop();
                var page = repo.page(plan.read(), checkpoint);
                transactions.executeWithoutResult(status -> {
                    insertBatches(page.items().stream().map(this::snapshotRow).toList(), mapper::stagePage);
                    if (page.last()) {
                        validateCompletedSnapshot(plan);
                    }
                    if (mapper.savePage(runKey(), PageKey.encode(page.lastEvaluatedKey()), page.last()) != 1) {
                        throw new IllegalStateException("DynamoDB page checkpoint could not be advanced");
                    }
                });
                if (page.last()) {
                    break;
                }
                checkpoint = page.lastEvaluatedKey();
            }
            log.info("DynamoDB source job={} runId={} pageLimit={} mode={} metrics={} {}",
                    context.job(), context.runId(), plan.read().limit(), plan.read().mode(), repo.metrics(), metrics);
        }
    }

    private void validateCompletedSnapshot(DynamoPlan plan) {
        if (plan.expectedItems() >= 0 && mapper.countWork(runKey()) != plan.expectedItems()) {
            throw new IllegalStateException("DynamoDB completed read count does not match");
        }
        if (context.job().equals("DynamoDbToPostgreSql") && mapper.validatePgKeys(runKey()) != 0) {
            throw new IllegalArgumentException("DynamoDB source must have positive canonical bigint customer keys");
        }
    }

    private void insertBatches(List<? extends DynamoMapper.Work> rows,
                               ToIntFunction<List<DynamoMapper.Work>> insert) {
        // PostgreSQL limits extended-query bind parameters to 65,535.
        for (int start = 0; start < rows.size(); start += INSERT_ROWS) {
            int end = Math.min(start + INSERT_ROWS, rows.size());
            var batch = List.<DynamoMapper.Work>copyOf(rows.subList(start, end));
            if (insert.applyAsInt(batch) != batch.size()) {
                throw new IllegalStateException("DynamoDB staging changed or had unexpected update counts");
            }
        }
    }

    private DynamoMapper.Work snapshotRow(DynamoCustomer customer) {
        var memo = customer.memo();
        String memoState = !memo.present() ? "ABSENT" : memo.value() == null ? "NULL" : "VALUE";
        return new DynamoMapper.Work(runKey(), customer.key().pk(), customer.key().sk(), customer.version(),
                customer.status(), customer.balance(), memoState, memo.value(), null);
    }

    void exportSnapshot() throws Exception {
        var state = mapper.state(runKey());
        if ("PREPARING".equals(state.state())) {
            throw new IllegalStateException("DynamoDB snapshot is not ready");
        }
        var output = files.output("customers");
        var columns = DynamoInputReader.FULL.toArray(String[]::new);
        files.export("customers", true, columns, sink -> {
            try {
                readOnly.executeWithoutResult(tx -> {
                    try (var cursor = mapper.stream(runKey())) {
                        for (var row : cursor) {
                            sink.row(Arrays.asList(row.pk(), row.sk(), Long.toString(row.version()), row.status(),
                                    output.formatNumber(row.balance()), row.memoState(), row.memo()));
                        }
                    } catch (Exception e) {
                        throw new ReadFailure(e);
                    }
                });
            } catch (ReadFailure e) {
                throw e.checkedCause();
            }
        });
    }

    void stagePg() {
        var plan = plan();
        var from = context.args().fromDate();
        var to = context.args().toDate();
        var seed = new DynamoMapper.PgSeed(runKey(), plan.read().partition(), plan.read().status(),
                from == null ? null : from.atStartOfDay(ZoneOffset.UTC).toInstant(),
                to == null ? null : to.atStartOfDay(ZoneOffset.UTC).toInstant());
        transactions.executeWithoutResult(status -> {
            mapper.start(runKey());
            if ("PREPARING".equals(mapper.state(runKey()).state())) {
                if (plan.deliversOutbox()) {
                    requireMutableGeneration(plan.read().partition());
                    verifyUpdated(mapper.stageOutbox(seed));
                } else {
                    mapper.seed(seed);
                    if (mapper.validatePgDelivery(runKey()) != 0) {
                        throw new IllegalArgumentException("PostgreSQL source exceeds DynamoDB item bounds");
                    }
                }
                if (mapper.seal(runKey()) != 1) {
                    throw new IllegalStateException("PostgreSQL source work could not be marked READY");
                }
            }
        });
    }

    void applyPg() {
        transactions.executeWithoutResult(status -> {
            var state = mapper.state(runKey());
            if (!"APPLIED".equals(state.state())) {
                if (!"READY".equals(state.state()) || mapper.validatePgKeys(runKey()) != 0) {
                    throw new IllegalArgumentException("DynamoDB source must have positive canonical bigint customer keys");
                }
                verifyUpdated(mapper.applyPg(runKey()));
                if (mapper.markApplied(runKey()) != 1) {
                    throw new IllegalStateException("PostgreSQL application could not be acknowledged");
                }
            }
        });
    }

    private static void verifyUpdated(DynamoMapper.Counts counts) {
        if (counts.expected() != counts.updated()) {
            throw new IllegalStateException("PostgreSQL expected and actual update counts differ");
        }
    }

    void requireMutableGeneration(String partition) {
        if (DynamoPlan.dedicatedGeneration(partition)
                && (mapper.generationOwner(partition) == null || mapper.assertGenerationWritable(partition) != null)) {
            throw new IllegalStateException("A reserved generation must be built and delivered before business changes");
        }
    }

    // Length prefixes keep the boundaries in stored revision and operation IDs stable.
    static String identityHash(String... fields) {
        try {
            var digest = MessageDigest.getInstance("SHA-256");
            for (String field : fields) {
                var bytes = field.getBytes(StandardCharsets.UTF_8);
                digest.update(ByteBuffer.allocate(Integer.BYTES).putInt(bytes.length).array());
                digest.update(bytes);
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static final class ReadFailure extends RuntimeException {
        private ReadFailure(Exception cause) {
            super(cause);
        }

        Exception checkedCause() {
            return (Exception) getCause();
        }
    }
}
