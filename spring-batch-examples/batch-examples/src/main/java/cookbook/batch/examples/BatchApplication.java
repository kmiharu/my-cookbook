package cookbook.batch.examples;

import cookbook.batch.common.BatchArguments;
import cookbook.batch.common.BatchProperties;
import cookbook.batch.database.PgArtifactLedger;
import cookbook.batch.file.FileSettings;
import cookbook.batch.storage.ArtifactLedger;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.apache.ibatis.annotations.Mapper;
import org.mybatis.spring.annotation.MapperScan;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;

@SpringBootApplication
@MapperScan(basePackages = "cookbook.batch.examples", annotationClass = Mapper.class)
public class BatchApplication {
    private static final Logger log = LoggerFactory.getLogger(BatchApplication.class);

    public static void main(String[] args) {
        System.exit(run(args));
    }

    static int run(String[] allArgs) {
        List<String> framework = new ArrayList<>();
        List<String> job = new ArrayList<>();
        for (String arg : allArgs) {
            if (arg.startsWith("--")) {
                if (!arg.startsWith("--spring.profiles.active=") &&
                        !arg.startsWith("--spring.config.additional-location=")) {
                    System.err.println("Unknown or disallowed Spring launch option");
                    return 2;
                }
                framework.add(arg);
            } else {
                job.add(arg);
            }
        }

        AtomicReference<RunContext> active = new AtomicReference<>();
        CountDownLatch finished = new CountDownLatch(1);
        Thread shutdown = new Thread(() -> {
            if (active.get() != null) {
                active.get().stopping().set(true);
            }
            try {
                finished.await(100, TimeUnit.SECONDS);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }, "batch-shutdown");
        Runtime.getRuntime().addShutdownHook(shutdown);
        try {
            BatchArguments raw = BatchArguments.parse(job, LaunchOptions.EXTRA);
            String jobName = LaunchOptions.jobName(raw);
            MDC.put("runId", raw.runId());
            MDC.put("job", jobName);
            SpringApplication app = new SpringApplication(BatchApplication.class);
            app.setRegisterShutdownHook(false);
            app.addInitializers(ctx -> {
                BatchProperties config = Binder.get(ctx.getEnvironment())
                        .bind("cookbook.batch", BatchProperties.class)
                        .orElse(new BatchProperties(Map.of(), Map.of()));
                String effectiveJob = LaunchOptions.jobName(raw.withValues(config.resolve(raw, null)));
                RunContext run = new RunContext(raw, config, effectiveJob);
                MDC.put("job", effectiveJob);
                LaunchOptions.validate(run);
                active.set(run);
                ctx.getBeanFactory().registerSingleton("runContext", run);
            });
            try (var application = app.run(framework.toArray(String[]::new))) {
                return application.getBean(JobRunner.class).execute();
            }
        } catch (IllegalArgumentException invalid) {
            log.error("Invalid launch: {}", invalid.getMessage());
            return 2;
        } catch (Exception failed) {
            if (active.get() != null && active.get().stopping().get()) {
                return 3;
            }
            log.error("Launch failed", failed);
            return 1;
        } finally {
            finished.countDown();
            try {
                Runtime.getRuntime().removeShutdownHook(shutdown);
            } catch (IllegalStateException ignored) {
                // A signal already started the shutdown hook.
            }
            MDC.clear();
        }
    }

    @Bean
    ArtifactLedger artifactLedger(JdbcTemplate jdbc, PlatformTransactionManager transaction) {
        return new PgArtifactLedger(jdbc, transaction);
    }
}
