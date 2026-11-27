package cookbook.batch.examples;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.job.builder.SimpleJobBuilder;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.core.step.builder.TaskletStepBuilder;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

@Configuration(proxyBeanMethods = false)
class StandardJobs {
    private static final Logger log = LoggerFactory.getLogger(StandardJobs.class);
    private final JobRepository jobs;
    private final PlatformTransactionManager transaction;
    private final RunContext run;
    private final JobFiles files;
    private final CustomerRepository customers;
    private final CustomerImportSteps imports;
    private final CustomerExportSteps exports;
    private final CustomerCopy copy;
    private final DatabaseBenchmarks benchmarks;

    StandardJobs(JobRepository jobs, PlatformTransactionManager transaction, RunContext run, JobFiles files,
                 CustomerRepository customers, CustomerImportSteps imports, CustomerExportSteps exports,
                 CustomerCopy copy, DatabaseBenchmarks benchmarks) {
        this.jobs = jobs;
        this.transaction = transaction;
        this.run = run;
        this.files = files;
        this.customers = customers;
        this.imports = imports;
        this.exports = exports;
        this.copy = copy;
        this.benchmarks = benchmarks;
    }

    @Bean
    Job standardJob(@Qualifier("stagedInputStep") Step stage, @Qualifier("validateInputStep") Step validate) {
        var job = new JobBuilder(run.job(), jobs);
        return switch (run.job()) {
            case "Seed" -> job.start(outside("seedCustomers", customers::seed)).build();
            case "CustomerExport", "FetchSizeBenchmark", "GzipBenchmark" ->
                    job.start(exports.directCustomers()).next(manifest()).build();
            case "WorkTableExport", "FullExport", "ParallelMultipartUpload" ->
                    job.start(snapshotCustomers()).next(exports.fixedCustomers()).next(manifest()).build();
            case "MultiFileExport" -> job.start(snapshotBoth())
                    .next(exports.fixedCustomers()).next(exports.fixedMembers()).next(manifest()).build();
            case "ParallelStep" -> job.start(snapshotBoth()).on("COMPLETED").to(exports.parallel())
                    .next(manifest()).end().build();
            case "Partitioned", "PartitionBenchmark" ->
                    job.start(snapshotCustomers()).next(exports.partitioned()).next(manifest()).build();
            case "CustomerImport" -> job.start(inside("reserveDirectInput", imports::reserveInput))
                    .next(imports.insertDirectly()).next(inside("checkDirectInput", imports::verifyCompleteInputs))
                    .build();
            case "CustomerUpsert", "MultiFileImport", "Restartable", "ChunkSizeBenchmark" ->
                    stageAndValidate(job, stage, validate).next(applyImport()).build();
            case "ValidatedImport", "SkipRecord" ->
                    stageAndValidate(job, stage, validate).next(applyImport())
                            .next(outside("exportInputErrors", imports::exportErrors)).next(manifest()).build();
            case "ImportAndExport" -> stageAndValidate(job, stage, validate).next(applyImport())
                    .next(outside("snapshotImported", customers::snapshotImported))
                    .next(exports.fixedCustomers()).next(manifest()).build();
            case "CopyExport" ->
                    job.start(outside("snapshotForCopy", () -> customers.snapshot("copy-customers", false)))
                            .next(outside("copyToStorage", copy::exportCustomers)).next(manifest()).build();
            case "CopyImport" -> job.start(outside("validateAndCopyInput", copy::importCustomers))
                    .next(validate).next(applyImport()).build();
            case "Retry" -> job.start(outside("retrySnapshotTransaction", exports::snapshotWithRetry))
                    .next(exports.fixedCustomers()).next(manifest()).build();
            case "FileArrivalCheck" -> job.start(outside("confirmFileArrival", () ->
                    log.info("ready input files={}", files.pinList().size()))).build();
            case "ChecksumValidation" -> stageAndValidate(job, stage, validate).build();
            case "FileTransfer" -> job.start(outside("transferPinnedObject", files::transfer))
                    .next(manifest()).build();
            case "SqlOptimization", "IndexOptimization" -> job.start(inside("explainQueries", benchmarks::explain)).build();
            case "BatchInsertBenchmark" -> job.start(outside("compareBatchInsert", benchmarks::insert)).build();
            default -> null;
        };
    }

    @Bean
    Step stagedInputStep() {
        return imports.stageRows();
    }

    @Bean
    Step validateInputStep() {
        return inside("validateWholeInput", imports::validateBeforeApply);
    }

    private SimpleJobBuilder stageAndValidate(JobBuilder job, Step stage, Step validate) {
        return job.start(inside("planInputWork", imports::prepare)).next(stage).next(validate);
    }

    private Step applyImport() {
        return inside("applyCustomerInput", imports::apply);
    }

    private Step snapshotCustomers() {
        return outside("snapshotCustomers", () -> customers.snapshot("customers", false));
    }

    private Step snapshotBoth() {
        return outside("snapshotCustomersAndMembers", () -> customers.snapshot("customers", true));
    }

    private Step manifest() {
        return outside("publishManifest", files::manifest);
    }

    private Step inside(String name, Action action) {
        return step(name, action).build();
    }

    private Step outside(String name, Action action) {
        return step(name, action).transactionAttribute(JobTasklets.withoutTransaction()).build();
    }

    private TaskletStepBuilder step(String name, Action action) {
        return new StepBuilder(name, jobs).tasklet(JobTasklets.interruptible(run, (contribution, chunk) -> {
            action.run();
            return RepeatStatus.FINISHED;
        }), transaction);
    }

    @FunctionalInterface
    private interface Action {
        void run() throws Exception;
    }
}
