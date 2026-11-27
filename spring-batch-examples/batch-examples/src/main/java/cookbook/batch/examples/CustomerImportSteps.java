package cookbook.batch.examples;

import java.util.List;
import java.util.function.BiConsumer;
import org.apache.ibatis.session.ExecutorType;
import org.apache.ibatis.session.SqlSessionFactory;
import org.mybatis.spring.SqlSessionTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Component
final class CustomerImportSteps {
    private static final String INPUT_CONSUMER = "customer-write";
    private static final Logger log = LoggerFactory.getLogger(CustomerImportSteps.class);
    private final JobRepository jobs;
    private final PlatformTransactionManager transaction;
    private final RunContext run;
    private final JobFiles files;
    private final JdbcTemplate jdbc;
    private final CustomerRepository customers;
    private final CustomerMapper mapper;
    private final SqlSessionTemplate batch;
    private final Environment environment;

    CustomerImportSteps(JobRepository jobs, PlatformTransactionManager transaction, RunContext run,
                        JobFiles files, JdbcTemplate jdbc, CustomerRepository customers, CustomerMapper mapper,
                        SqlSessionFactory sessions, Environment environment) {
        this.jobs = jobs;
        this.transaction = transaction;
        this.run = run;
        this.files = files;
        this.jdbc = jdbc;
        this.customers = customers;
        this.mapper = mapper;
        this.batch = new SqlSessionTemplate(sessions, ExecutorType.BATCH);
        this.environment = environment;
    }

    Step stageRows() {
        return readChunks("stageInputChunks", CustomerMapper::stage);
    }

    Step insertDirectly() {
        return readChunks("insertInputChunks", CustomerMapper::insert);
    }

    void prepare() {
        customers.beginWork("input");
    }

    void validateBeforeApply() {
        verifyCompleteInputs();
        prepare();
        customers.ready("input");
    }

    private Step readChunks(String stepName, BiConsumer<CustomerMapper, InputCustomer> writeValidRow) {
        var reader = new CustomerInputReader(run, files, jdbc);
        return new StepBuilder(stepName, jobs).<InputCustomer, InputCustomer>chunk(run.chunkSize())
                .transactionManager(transaction).reader(reader).writer(chunk -> {
                    fault("BEFORE_CHUNK_WRITE");
                    CustomerMapper writer = batch.getMapper(CustomerMapper.class);
                    for (var row : chunk) {
                        if (row.error() == null) {
                            writeValidRow.accept(writer, row);
                        } else {
                            writer.error(row);
                        }
                    }
                    batch.flushStatements();
                    fault("AFTER_CHUNK_WRITE");
                    if (environment.matchesProfiles("fault-test")) {
                        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                            @Override
                            public void afterCommit() {
                                fault("AFTER_CHUNK_COMMIT");
                            }
                        });
                    }
                }).build();
    }

    void reserveInput() {
        for (var input : files.pinList()) {
            String revision = input.versionId() == null ? input.eTag() : input.versionId();
            jdbc.update("""
                    INSERT INTO batch_input_applied (consumer,bucket,object_key,revision,run_id,job_name)
                    VALUES (?,?,?,?,?,?) ON CONFLICT (consumer,bucket,object_key,revision) DO NOTHING
                    """, INPUT_CONSUMER, input.bucket(), input.key(), revision, run.runId(), run.job());
            Boolean owned = jdbc.queryForObject("""
                    SELECT run_id=? AND job_name=? FROM batch_input_applied
                    WHERE consumer=? AND bucket=? AND object_key=? AND revision=?
                    """, Boolean.class, run.runId(), run.job(), INPUT_CONSUMER, input.bucket(), input.key(), revision);
            if (!Boolean.TRUE.equals(owned)) {
                throw new IllegalStateException("Input revision already consumed by another run");
            }
        }
    }

    void verifyCompleteInputs() {
        Long confirmed = jdbc.queryForObject("""
                SELECT COUNT(*) FROM batch_input_check WHERE job_name=? AND run_id=?
                """, Long.class, run.job(), run.runId());
        if (confirmed == null || confirmed != files.pinList().size()) {
            throw new IllegalStateException("One or more inputs have not passed complete validation");
        }
    }

    void apply() {
        int updated = jdbc.update("""
                UPDATE batch_work_status SET state='APPLIED'
                WHERE job_name=? AND run_id=? AND work_kind='input' AND state='READY'
                """, run.job(), run.runId());
        if (updated != 1) {
            throw new IllegalStateException("Input work is not ready to apply");
        }
        reserveInput();
        Long expected = jdbc.queryForObject(
                "SELECT COUNT(*) FROM batch_input_work WHERE job_name=? AND run_id=?",
                Long.class, run.job(), run.runId());
        long applied = mapper.upsert(run.job(), run.runId());
        if (expected == null || applied != expected) {
            throw new IllegalStateException("Expected existing versions or insertion count changed: expected="
                    + expected + " applied=" + applied);
        }
        log.info("apply customer confirmedRows={}", applied);
    }

    void exportErrors() throws Exception {
        files.export("errors", true, new String[]{"fileIndex", "logicalRecord", "reason"},
                sink -> customers.errors(error -> sink.row(List.of(Integer.toString(error.fileIndex() + 1),
                        Long.toString(error.ordinal()), error.reason()))));
    }

    private void fault(String phase) {
        if (!environment.matchesProfiles("fault-test") || !phase.equals(environment.getProperty("BATCH_FAULT_PHASE"))) {
            return;
        }
        String action = environment.getProperty("BATCH_FAULT_ACTION", "fail");
        if ("halt".equals(action)) {
            Runtime.getRuntime().halt(97);
        }
        if ("pause".equals(action)) {
            log.info("Fault test waiting at {}", phase);
            while (!run.stopping().get()) {
                try {
                    Thread.sleep(250);
                } catch (InterruptedException stopped) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("Fault test interrupted", stopped);
                }
            }
        }
        if ("oom".equals(action)) {
            byte[] oversized = new byte[600 * 1024 * 1024];
            throw new IllegalStateException("Fault test requires a heap smaller than " + oversized.length + " bytes");
        }
        throw new IllegalStateException("Injected failure at " + phase);
    }
}
