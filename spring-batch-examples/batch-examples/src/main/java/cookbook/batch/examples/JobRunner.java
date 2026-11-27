package cookbook.batch.examples;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.InputStream;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.JobExecution;
import org.springframework.batch.core.job.parameters.JobParametersBuilder;
import org.springframework.batch.core.launch.JobOperator;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.context.ApplicationContext;
import org.springframework.core.env.Environment;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Component
final class JobRunner {
    private static final Logger log = LoggerFactory.getLogger(JobRunner.class);
    private final DataSource source;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transactions;
    private final JobRepository repository;
    private final JobOperator operator;
    private final ApplicationContext spring;
    private final RunContext run;
    private final JobFiles files;
    private final Environment env;

    JobRunner(DataSource source, JdbcTemplate jdbc, PlatformTransactionManager tx,
              JobRepository repository, JobOperator operator, ApplicationContext spring,
              RunContext run, JobFiles files, Environment env) {
        this.source = source;
        this.jdbc = jdbc;
        this.transactions = new TransactionTemplate(tx);
        this.repository = repository;
        this.operator = operator;
        this.spring = spring;
        this.run = run;
        this.files = files;
        this.env = env;
    }

    int execute() throws Exception {
        if (run.job().equals("Migrate")) {
            return migrate();
        }
        Job job = spring.getBeansOfType(Job.class).values().stream()
                .filter(candidate -> candidate.getName().equals(run.job()))
                .findFirst().orElseThrow(() -> new IllegalArgumentException("Job is unavailable: " + run.job()));
        var parameters = new JobParametersBuilder().addString("runId", run.runId(), true).toJobParameters();
        String signature = signature();
        String token = UUID.randomUUID().toString();
        String location = env.getProperty("BATCH_EXECUTION_OWNER", env.getProperty("HOSTNAME", "host"));
        String mutex = run.job() + "/" + run.runId();

        try (Connection lock = source.getConnection()) {
            if (!advisory(lock, "pg_try_advisory_lock", mutex)) {
                throw new IllegalStateException("Run already owns the lock");
            }
            try {
                JobExecution last = repository.getLastJobExecution(job.getName(), parameters);
                if (last != null && last.getStatus() == BatchStatus.COMPLETED) {
                    checkSettings(signature);
                    jdbc.update("UPDATE batch_run SET state='COMPLETED',updated_at=clock_timestamp() "
                            + "WHERE job_name=? AND run_id=? AND state='ACTIVE'", run.job(), run.runId());
                    log.info("Already completed executionId={}", last.getId());
                    return 0;
                }
                transactions.executeWithoutResult(status -> {
                    acquire(signature, token, location, last);
                });
                try {
                    if (LaunchOptions.needsInput(run.job())) {
                        transactions.executeWithoutResult(status -> files.pinList());
                    }
                    run.checkStop();
                    JobExecution execution = last == null ? operator.start(job, parameters) : operator.restart(last);
                    BatchStatus state = execution.getStatus();
                    for (var step : execution.getStepExecutions()) {
                        log.info("step={} status={} read={} write={} skip={} commits={} rollbacks={} started={} ended={}",
                                step.getStepName(), step.getStatus(), step.getReadCount(), step.getWriteCount(),
                                step.getSkipCount(), step.getCommitCount(), step.getRollbackCount(),
                                step.getStartTime(), step.getEndTime());
                    }
                    boolean stopping = run.stopping().get() || state == BatchStatus.STOPPED;
                    finish(token, state == BatchStatus.COMPLETED ? "COMPLETED" : stopping ? "STOPPED" : "FAILED");
                    log.info("executionId={} instanceId={} status={}", execution.getId(), execution.getJobInstance().getId(), state);
                    return state == BatchStatus.COMPLETED ? 0 : stopping ? 3 : 1;
                } catch (Exception error) {
                    finish(token, run.stopping().get() ? "STOPPED" : "FAILED");
                    throw error;
                }
            } finally {
                if (lock.isValid(2)) {
                    advisory(lock, "pg_advisory_unlock", mutex);
                }
            }
        }
    }

    private int migrate() {
        var config = Flyway.configure().dataSource(source);
        var migrations = config.load().migrate();
        log.info("database migration applied={}", migrations.migrationsExecuted);
        cookbook.batch.examples.operations.MigrationTarget.prepare(env);
        return 0;
    }

    private void acquire(String signature, String token, String location, JobExecution last) {
        var entry = checkSettings(signature);
        if (entry == null) {
            jdbc.update("INSERT INTO batch_run(job_name,run_id,state,settings,owner,owner_location) VALUES (?,?,'ACTIVE',?,?,?)",
                    run.job(), run.runId(), signature, token, location);
            return;
        }
        if ("ACTIVE".equals(entry.state())) {
            if (!entry.location().equals(run.value("recover.owner", "")) || run.number("recover.executionId", -1, 0, Long.MAX_VALUE) != (last == null ? 0 : last.getId())) {
                throw new IllegalStateException("Active owner " + entry.location()
                        + "; verify it has stopped before supplying recover.owner and recover.executionId");
            }
            if (last != null && last.getStatus().isRunning()) {
                operator.recover(last);
            }
        }
        int claimed = jdbc.update("""
                UPDATE batch_run SET state='ACTIVE',owner=?,owner_location=?,updated_at=clock_timestamp()
                WHERE job_name=? AND run_id=? AND owner=?
                """, token, location, run.job(), run.runId(), entry.token());
        if (claimed != 1) {
            throw new IllegalStateException("Run ownership changed unexpectedly");
        }
    }

    private Registration checkSettings(String signature) {
        var entries = jdbc.query("""
                SELECT state,settings,owner,owner_location FROM batch_run WHERE job_name=? AND run_id=?
                """, (rs, n) -> new Registration(rs.getString(1), rs.getString(2), rs.getString(3), rs.getString(4)),
                run.job(), run.runId());
        if (entries.isEmpty()) {
            return null;
        }
        Registration entry = entries.getFirst();
        if (!entry.settings().equals(signature)) {
            throw new IllegalArgumentException("Resolved settings or code changed for this run; choose a new runId");
        }
        return entry;
    }

    private void finish(String owner, String state) {
        int count = jdbc.update("""
                UPDATE batch_run SET state=?,updated_at=clock_timestamp() WHERE job_name=? AND run_id=? AND owner=?
                """, state, run.job(), run.runId(), owner);
        if (count != 1) {
            throw new IllegalStateException("Could not release owned run");
        }
    }

    private String signature() throws Exception {
        var options = new TreeMap<>(run.options());
        options.remove("recover.executionId");
        options.remove("recover.owner");
        // Preserve options for every configured file, including those in steps which a restart will skip.
        var actualOptions = new TreeMap<String, Object>();
        actualOptions.put("jobOptions", options);
        var configured = run.properties().jobs().get(run.raw().job());
        if (configured != null) {
            var fileOptions = new TreeMap<String, Map<String, String>>();
            for (String key : configured.files().keySet()) {
                var resolved = new TreeMap<>(run.fileOptions(key));
                resolved.remove("recover.executionId");
                resolved.remove("recover.owner");
                fileOptions.put(key, resolved);
            }
            actualOptions.put("fileOptions", fileOptions);
        }
        var storage = new TreeMap<String, String>();
        for (String target : Arrays.asList("INPUT", "INTERNAL", "PARTNER")) {
            for (String key : Arrays.asList("BUCKET", "REGION", "PREFIX", "ROLE_ARN")) {
                String name = "BATCH_" + target + "_" + key;
                storage.put(name, env.getProperty(name, ""));
            }
        }
        for (String key : Arrays.asList("BATCH_S3_ENDPOINT", "BATCH_DYNAMO_ENDPOINT",
                "BATCH_DYNAMO_TABLE", "BATCH_DYNAMO_OPERATIONS_TABLE", "BATCH_DYNAMO_REGION",
                "batch.dynamo.endpoint", "batch.dynamo.table", "batch.dynamo.operations-table", "batch.dynamo.region")) {
            storage.put(key, env.getProperty(key, ""));
        }
        if (run.job().equals("DataMigration")) {
            String target = env.getProperty("BATCH_TARGET_DB_URL", "");
            String targetIdentity = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(target.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
            actualOptions.put("targetRoutingSha256", targetIdentity);
        }
        if (cookbook.batch.examples.dynamo.DynamoJobs.JOBS.contains(run.job())) {
            actualOptions.put("dynamo", spring.getBean(cookbook.batch.examples.dynamo.DynamoSettings.class));
        }
        actualOptions.put("storage", storage);
        actualOptions.put("codeSha256", definitionFingerprint());
        return new ObjectMapper().writeValueAsString(actualOptions);
    }

    private static String definitionFingerprint() throws Exception {
        var resolver = new PathMatchingResourcePatternResolver();
        var resources = new ArrayList<Resource>();
        for (String pattern : Arrays.asList("classpath*:cookbook/batch/**/*.class",
                "classpath*:mapper/*.xml", "classpath*:db/migration/*.sql", "classpath*:db/migration-target/*.sql")) {
            resources.addAll(Arrays.asList(resolver.getResources(pattern)));
        }
        resources.sort(Comparator.comparing(Resource::getFilename));
        var digest = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[32 * 1024];
        for (Resource resource : resources) {
            try (InputStream resourceStream = resource.getInputStream()) {
                for (int read; (read = resourceStream.read(buffer)) != -1;) {
                    digest.update(buffer, 0, read);
                }
            }
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private static boolean advisory(Connection lock, String function, String mutex) throws Exception {
        String sql = function.equals("pg_try_advisory_lock")
                ? "SELECT pg_try_advisory_lock(hashtextextended(?,42))"
                : "SELECT pg_advisory_unlock(hashtextextended(?,42))";
        try (PreparedStatement statement = lock.prepareStatement(sql)) {
            statement.setString(1, mutex);
            try (var rows = statement.executeQuery()) {
                return rows.next() && rows.getBoolean(1);
            }
        }
    }

    private record Registration(String state, String settings, String token, String location) {}
}
