package cookbook.batch.examples;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.batch.core.job.builder.FlowBuilder;
import org.springframework.batch.core.job.flow.Flow;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.core.step.tasklet.Tasklet;
import org.springframework.batch.infrastructure.item.ExecutionContext;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.core.env.Environment;
import org.springframework.core.task.SimpleAsyncTaskExecutor;
import org.springframework.dao.TransientDataAccessException;
import org.springframework.dao.TransientDataAccessResourceException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;

@Component
final class CustomerExportSteps {
    private static final Logger log = LoggerFactory.getLogger(CustomerExportSteps.class);
    private static final String[] CUSTOMERS = {"id", "name", "email", "status"};
    private static final String[] MEMBERS = {"id", "memberId", "name", "email", "status", "tier"};
    private final JobRepository jobs;
    private final PlatformTransactionManager transaction;
    private final RunContext run;
    private final JobFiles files;
    private final JdbcTemplate jdbc;
    private final CustomerRepository customers;
    private final Environment environment;

    CustomerExportSteps(JobRepository jobs, PlatformTransactionManager transaction, RunContext run,
                        JobFiles files, JdbcTemplate jdbc, CustomerRepository customers, Environment environment) {
        this.jobs = jobs;
        this.transaction = transaction;
        this.run = run;
        this.files = files;
        this.jdbc = jdbc;
        this.customers = customers;
        this.environment = environment;
    }

    Step directCustomers() {
        return exportStep("streamCustomerCursor", (contribution, chunk) -> {
            writeCustomers("customers", false, customers::direct);
            return RepeatStatus.FINISHED;
        });
    }

    Step fixedCustomers() {
        return exportStep("export-customers", (contribution, chunk) -> {
            writeCustomerRange("customers", 0, Long.MAX_VALUE);
            return RepeatStatus.FINISHED;
        });
    }

    Step fixedMembers() {
        return exportStep("export-customer-members", (contribution, chunk) -> {
            var format = files.output("customer-members");
            files.export("customer-members", true, MEMBERS, sink ->
                    customers.work("customer-members", 0, Long.MAX_VALUE, row ->
                            sink.row(Arrays.asList(
                                    format.formatNumber(BigDecimal.valueOf(row.customerId())),
                                    row.memberId() == 0 ? null : format.formatNumber(BigDecimal.valueOf(row.memberId())),
                                    row.name(), row.email(), row.status(), row.tier()))));
            return RepeatStatus.FINISHED;
        });
    }

    Flow parallel() {
        var customerFlow = new FlowBuilder<Flow>("customersFlow").start(fixedCustomers()).build();
        var membersFlow = new FlowBuilder<Flow>("membersFlow").start(fixedMembers()).build();
        return new FlowBuilder<Flow>("parallelArtifactFlows").split(executor(2)).add(customerFlow, membersFlow).build();
    }

    Step partitioned() {
        var worker = exportStep("exportKeyRange", (contribution, chunk) -> {
            ExecutionContext bounds = contribution.getStepExecution().getExecutionContext();
            writeCustomerRange(bounds.getString("artifact"), bounds.getLong("from"), bounds.getLong("to"));
            return RepeatStatus.FINISHED;
        });
        return new StepBuilder("partitionCustomers", jobs).partitioner(worker.getName(), grid -> ranges())
                .gridSize(run.partitions()).taskExecutor(executor(run.partitions())).step(worker).build();
    }

    private void writeCustomerRange(String artifact, long from, long to) throws Exception {
        writeCustomers(artifact, true, writer -> customers.work("customers", from, to, writer));
    }

    private void writeCustomers(String artifact, boolean reproducible, CustomerRows source) throws Exception {
        var format = files.output(artifact);
        files.export(artifact, reproducible, CUSTOMERS, sink ->
                source.stream(row -> sink.row(Arrays.asList(format.formatNumber(BigDecimal.valueOf(row.customerId())),
                        row.name(), row.email(), row.status()))));
    }

    private Step exportStep(String name, Tasklet action) {
        return new StepBuilder(name, jobs).tasklet(JobTasklets.interruptible(run, action), transaction)
                .transactionAttribute(JobTasklets.withoutTransaction()).build();
    }

    private Map<String, ExecutionContext> ranges() {
        long[] bounds = jdbc.queryForObject("""
                SELECT COALESCE(MIN(customer_id),1),COALESCE(MAX(customer_id),1)
                FROM batch_customer_export WHERE job_name=? AND run_id=? AND artifact='customers'
                """, (rs, row) -> new long[]{rs.getLong(1), rs.getLong(2)}, run.job(), run.runId());
        // An exclusive upper bound of Long.MAX_VALUE + 1 still fits in BigInteger.
        BigInteger start = BigInteger.valueOf(bounds[0]);
        BigInteger endExclusive = BigInteger.valueOf(bounds[1]).add(BigInteger.ONE);
        BigInteger length = endExclusive.subtract(start);
        BigInteger partitionCount = length.min(BigInteger.valueOf(run.partitions()));
        var result = new LinkedHashMap<String, ExecutionContext>();
        for (int index = 0; index < partitionCount.intValueExact(); index++) {
            String name = "part-%02d".formatted(index);
            BigInteger firstOffset = length.multiply(BigInteger.valueOf(index)).divide(partitionCount);
            BigInteger nextOffset = length.multiply(BigInteger.valueOf(index + 1)).divide(partitionCount);
            var values = new ExecutionContext();
            values.putString("artifact", "customers-" + name);
            values.putLong("from", start.add(firstOffset).longValueExact());
            values.putLong("to", start.add(nextOffset).subtract(BigInteger.ONE).longValueExact());
            result.put(name, values);
        }
        return result;
    }

    private static SimpleAsyncTaskExecutor executor(int count) {
        SimpleAsyncTaskExecutor executor = new SimpleAsyncTaskExecutor("batch-worker-");
        executor.setConcurrencyLimit(count);
        executor.setTaskTerminationTimeout(10_000);
        executor.setTaskDecorator(task -> {
            var logContext = MDC.getCopyOfContextMap();
            return () -> {
                if (logContext != null) {
                    MDC.setContextMap(logContext);
                }
                try {
                    task.run();
                } finally {
                    MDC.clear();
                }
            };
        });
        return executor;
    }

    void snapshotWithRetry() throws Exception {
        for (int attempt = 1; ; attempt++) {
            try {
                if (attempt == 1 && environment.matchesProfiles("fault-test") &&
                        "RETRY_SNAPSHOT".equals(environment.getProperty("BATCH_FAULT_PHASE"))) {
                    throw new TransientDataAccessResourceException("Injected transient failure");
                }
                customers.snapshot("customers", false);
                return;
            } catch (TransientDataAccessException error) {
                if (attempt == 3) {
                    throw error;
                }
                log.warn("retrying transient PostgreSQL error attempt={}", attempt);
                run.checkStop();
                Thread.sleep(100L * attempt);
            }
        }
    }

    @FunctionalInterface
    private interface CustomerRows {
        void stream(CustomerRepository.CheckedRow<CustomerRow> writer) throws Exception;
    }
}
