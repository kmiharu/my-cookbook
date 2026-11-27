package cookbook.batch.examples.dynamo;

import cookbook.batch.examples.JobFiles;
import cookbook.batch.examples.JobTasklets;
import cookbook.batch.examples.RunContext;
import cookbook.batch.file.FileSettings;
import java.util.Set;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.transaction.PlatformTransactionManager;

@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(DynamoSettings.class)
public class DynamoJobs {
    public static final Set<String> JOBS = Set.of("DynamoDbQueryExport", "DynamoDbScanExport", "DynamoDbImport",
            "DynamoDbConditionalUpdate", "DynamoDbDelete", "PostgreSqlToDynamoDb", "DynamoDbToPostgreSql",
            "DynamoDbBenchmark");
    public static final Set<String> OPTIONS = Set.of("dynamo.partition", "dynamo.gsi", "dynamo.status",
            "dynamo.pageLimit", "dynamo.batchSize", "dynamo.workers", "dynamo.rateLimit", "dynamo.readMode",
            "dynamo.consistentRead", "dynamo.writeMode", "dynamo.operation", "dynamo.targetPartition",
            "dynamo.retryAttempts", "dynamo.retrySeconds", "dynamo.expectedItems");
    private static final Set<String> INPUT = Set.of("DynamoDbImport", "DynamoDbConditionalUpdate", "DynamoDbDelete");

    private final RunContext context;
    private final JobFiles files;
    private final JobRepository jobRepository;
    private final PlatformTransactionManager transactionManager;
    private final DynamoWork work;
    private final DynamoDelivery delivery;

    public DynamoJobs(RunContext context, JobFiles files, DynamoMapper mapper, JobRepository jobRepository,
            PlatformTransactionManager transactionManager, DynamoSettings settings, Environment environment) {
        this.context = context;
        this.files = files;
        this.jobRepository = jobRepository;
        this.transactionManager = transactionManager;
        this.work = new DynamoWork(context, files, mapper, settings, environment, transactionManager);
        this.delivery = new DynamoDelivery(context, files, mapper, settings, environment, transactionManager, work);
        if (JOBS.contains(context.job())) {
            validateConfiguration(context, settings);
        }
    }

    public static void validate(RunContext context) {
        if (!JOBS.contains(context.job())) {
            return;
        }
        // Job is selected after Spring prepares its configuration. Validate explicit values at launch.
        var defaults = new DynamoSettings("us-east-1", "batch-dynamo-customers", "batch-dynamo-operations", null,
                "by-status", "demo", "QUERY", 100, 25, 1, 0, 4, 30);
        validateConfiguration(context, defaults);
    }

    private static void validateConfiguration(RunContext context, DynamoSettings settings) {
        DynamoPlan plan = DynamoPlan.from(context, settings);
        if (INPUT.contains(context.job())) {
            var spec = FileSettings.from(context.fileOptions("input-1"), "input");
            var columns = DynamoInputReader.columns(context.job(), plan);
            DynamoInputReader.verifyColumns(columns, spec.columnsOr(columns));
        }
        if (!context.job().equals("DynamoDbToPostgreSql")) {
            boolean snapshot = context.job().endsWith("Export") || context.job().endsWith("Benchmark");
            String artifact = snapshot ? "customers" : "delivery";
            var allowed = snapshot ? DynamoInputReader.FULL : DynamoDelivery.REPORT_COLUMNS;
            var columns = FileSettings.from(context.fileOptions(artifact), "output").columns();
            if (!allowed.containsAll(columns)) {
                throw new IllegalArgumentException("Unsupported DynamoDB output column");
            }
        }
    }

    @Bean
    Job DynamoDbQueryExport() {
        return exportJob("DynamoDbQueryExport");
    }

    @Bean
    Job DynamoDbScanExport() {
        return exportJob("DynamoDbScanExport");
    }

    @Bean
    Job DynamoDbToPostgreSql() {
        String name = "DynamoDbToPostgreSql";
        return new JobBuilder(name, jobRepository)
                .start(step(name + "-stage", work::stageDynamoSnapshot))
                .next(step(name + "-apply", work::applyPg))
                .build();
    }

    @Bean
    Job DynamoDbBenchmark() {
        return new JobBuilder("DynamoDbBenchmark", jobRepository)
                .start(step("dynamoBenchmarkStage", work::stageDynamoSnapshot))
                .next(step("dynamoBenchmarkBatchWrite", delivery::benchmarkWrite))
                .next(step("dynamoBenchmarkExport", work::exportSnapshot))
                .next(step("dynamoBenchmarkManifest", files::manifest))
                .build();
    }

    @Bean
    Job DynamoDbImport() {
        return inputJob("DynamoDbImport");
    }

    @Bean
    Job DynamoDbConditionalUpdate() {
        return inputJob("DynamoDbConditionalUpdate");
    }

    @Bean
    Job DynamoDbDelete() {
        return inputJob("DynamoDbDelete");
    }

    @Bean
    Job PostgreSqlToDynamoDb() {
        String name = "PostgreSqlToDynamoDb";
        return new JobBuilder(name, jobRepository)
                .start(step("postgresToDynamoStage", work::stagePg))
                .next(step("postgresToDynamoDeliver", delivery::deliverPg))
                .next(step("postgresToDynamoReport", delivery::writeReport))
                .next(step("postgresToDynamoManifest", files::manifest))
                .build();
    }

    private Job exportJob(String name) {
        return new JobBuilder(name, jobRepository)
                .start(step(name + "-stage", work::stageDynamoSnapshot))
                .next(step(name + "-export", work::exportSnapshot))
                .next(step(name + "-manifest", files::manifest))
                .build();
    }

    private Job inputJob(String name) {
        var chunk = new StepBuilder(name + "-stage", jobRepository)
                .<DynamoMapper.Work, DynamoMapper.Work>chunk(context.chunkSize())
                .reader(work.inputReader())
                .writer(items -> work.stageInputRows(items.getItems()))
                .transactionManager(transactionManager)
                .build();
        return new JobBuilder(name, jobRepository)
                .start(step(name + "-prepare", work::startInput))
                .next(chunk)
                .next(step(name + "-seal", work::sealInput))
                .next(step(name + "-deliver", delivery::deliverInput))
                .next(step(name + "-report", delivery::writeReport))
                .next(step(name + "-manifest", files::manifest))
                .build();
    }

    private Step step(String name, Action action) {
        return new StepBuilder(name, jobRepository).tasklet(JobTasklets.interruptible(context, (contribution, chunk) -> {
                    action.run();
                    return RepeatStatus.FINISHED;
                }), transactionManager)
                .transactionAttribute(JobTasklets.withoutTransaction())
                .build();
    }

    @FunctionalInterface
    private interface Action {
        void run() throws Exception;
    }
}
