package cookbook.batch.examples.operations;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

import cookbook.batch.examples.JobFiles;
import cookbook.batch.examples.JobTasklets;
import cookbook.batch.examples.RunContext;
import cookbook.batch.file.FileSettings;

import org.springframework.batch.core.job.Job;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.job.flow.FlowExecutionStatus;
import org.springframework.batch.core.job.flow.JobExecutionDecider;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.Step;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.infrastructure.repeat.RepeatStatus;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import static cookbook.batch.examples.operations.OperationModels.*;

@Configuration(proxyBeanMethods = false)
public class OperationsJobs {
    private static final String[] CUSTOMER_COLUMNS = {
            "id", "name", "email", "status", "updated_at", "version", "detail"
    };
    private static final String[] PATCH_PREVIEW_COLUMNS = {"id", "old_status", "new_status", "old_version"};
    private static final String[] PATCH_BACKUP_COLUMNS = {"id", "old_status", "old_version"};
    private static final String[] PATCH_DIFF_COLUMNS = {"id", "old_status", "new_status", "old_version", "applied_version"};
    private static final String[] PATCH_RESTORE_COLUMNS = {"id", "restored_status", "applied_version", "restored_version"};

    public static void validateFileOptions(RunContext context) {
        Map<String, String[]> artifacts = switch (context.job()) {
            case "DataTransform" -> Map.of("transformed", CUSTOMER_COLUMNS);
            case "DataReconciliation" -> Map.of("reconciliation", CUSTOMER_COLUMNS);
            case "DataPatchPreview" -> Map.of("patch-preview", PATCH_PREVIEW_COLUMNS);
            case "DataPatchApply" -> Map.of("patch-backup", PATCH_BACKUP_COLUMNS, "patch-diff", PATCH_DIFF_COLUMNS);
            case "DataPatchRestore" -> Map.of("patch-restore", PATCH_RESTORE_COLUMNS);
            case "DataArchive" -> Map.of("archive", CUSTOMER_COLUMNS);
            case "ConditionalFlow" -> Map.of("conditional", CUSTOMER_COLUMNS);
            case "IncrementalExport" -> Map.of("incremental", CUSTOMER_COLUMNS);
            default -> Map.of();
        };
        artifacts.forEach((artifact, fields) -> {
            var columns = FileSettings.from(context.fileOptions(artifact), "output").columnsOr(List.of(fields));
            if (!List.of(fields).containsAll(columns)) {
                throw new IllegalArgumentException("Unknown output column for " + artifact);
            }
            if (artifact.equals("archive") && !columns.containsAll(List.of("id", "name", "email", "status", "updated_at", "version"))
                    || artifact.startsWith("patch-") && !columns.containsAll(List.of(fields))) {
                throw new IllegalArgumentException("Missing required archive or patch audit columns for " + artifact);
            }
        });
    }

    private final JobRepository jobRepository;
    private final PlatformTransactionManager transactions;
    private final OperationsRepository operations;
    private final RunContext context;
    private final OperationsParameters parameters;
    private final JobFiles files;
    private final Environment environment;

    public OperationsJobs(JobRepository jobRepository, PlatformTransactionManager transactions,
                          OperationsRepository operations, RunContext context, JobFiles files, Environment environment) {
        this.jobRepository = jobRepository;
        this.transactions = transactions;
        this.operations = operations;
        this.context = context;
        this.parameters = new OperationsParameters(context.options());
        this.files = files;
        this.environment = environment;
    }

    @Bean
    Job customerDelete(@Qualifier("stagedInputStep") Step stage, @Qualifier("validateInputStep") Step validate) {
        return job("CustomerDelete").start(stage)
                .next(validate)
                .next(step("freezeDeleteKeys", () -> operations.freezeDeletes(scope())))
                .next(step("deleteVersionMatchedCustomers", () -> operations.applyInputDeletes(run())))
                .build();
    }

    @Bean
    Job dataTransform() {
        return job("DataTransform")
                .start(step("freezeTransformWork", () -> operations.freeze(scope())))
                .next(step("normalizeTransformWork", () -> operations.transform(run())))
                .next(external("exportTransformedCustomers", () -> exportWork("transformed")))
                .next(manifest())
                .build();
    }

    @Bean
    Job aggregation() {
        return job("Aggregation")
                .start(step("replaceCustomerSummaryPeriod", () -> operations.aggregate(parameters.period())))
                .build();
    }

    @Bean
    Job statusUpdate() {
        return job("StatusUpdate")
                .start(step("freezeStatusConditions", () -> operations.freezeStatus(scope())))
                .next(step("applyVersionMatchedStatus", () -> operations.updateAll(run(), false)))
                .next(step("verifyStatusUpdates", () -> operations.verifyUpdates(run())))
                .build();
    }

    @Bean
    Job bulkUpdate() {
        return job("BulkUpdate")
                .start(step("freezeBulkUpdateConditions", () -> operations.freezeStatus(scope())))
                .next(updateStep("applyBulkUpdates", "BulkUpdate", false))
                .next(step("verifyBulkUpdates", () -> operations.verifyUpdates(run())))
                .build();
    }

    @Bean
    Job dataReconciliation(@Qualifier("stagedInputStep") Step stage, @Qualifier("validateInputStep") Step validate) {
        return job("DataReconciliation").start(stage)
                .next(validate)
                .next(step("freezeReconciledCustomers", () -> operations.reconcile(scope())))
                .next(external("exportReconciliation", () -> exportWork("reconciliation")))
                .next(manifest())
                .build();
    }

    @Bean
    Job dataMigration() {
        final String name = "DataMigration";
        return job(name)
                .start(external("validateMigrationTargetSchema", () -> {
                    MigrationTarget target = migrationTarget();
                    target.verifySeparate(environment);
                    target.validateSchema();
                }))
                .next(step("freezeMigrationSource", () -> operations.freeze(scope())))
                .next(migrationChunkStep())
                .build();
    }

    private Step migrationChunkStep() {
        return new StepBuilder("copyToSeparatePostgres", jobRepository)
                .<CustomerRow, CustomerRow>chunk(parameters.chunkSize()).transactionManager(transactions)
                .reader(new OperationPageReader<>(
                        after -> operations.operationPage(run(), after, parameters.chunkSize()), CustomerRow::id))
                .writer(chunk -> {
                    context.checkStop();
                    migrationTarget().copy(context.runId(), chunk.getItems(), context.stopping()::get);
                    if (environment.matchesProfiles("fault-test")
                            && environment.getProperty("BATCH_MIGRATION_HALT_AFTER_TARGET_COMMIT", "false").equals("true")) {
                        Runtime.getRuntime().halt(97);
                    }
                })
                .build();
    }

    @Bean
    Job dataPatchPreview() {
        return job("DataPatchPreview")
                .start(step("freezePreviewPlan", () -> operations.previewPatch(scope(), parameters.patchId(), parameters.planId())))
                .next(external("exportPatchPreview", this::exportPatchPreview))
                .next(manifest())
                .build();
    }

    @Bean
    Job dataPatchApply() {
        return patchJob("DataPatchApply", false, this::exportAppliedPatch);
    }

    @Bean
    Job dataPatchRestore() {
        return patchJob("DataPatchRestore", true, this::exportRestoredPatch);
    }

    private Job patchJob(String name, boolean restore, Action publish) {
        if (context.job().equals(name) && parameters.mode().equals("chunk")) {
            return job(name).start(step("claimPatchPlan", () -> startPatch(restore)))
                    .next(patchChunkStep(restore))
                    .next(step("verifyPatchAudit", () -> finishPatch(restore)))
                    .next(external("exportPatchAudit", publish))
                    .next(manifest())
                    .build();
        }
        return job(name).start(step("applyAndRecordPatchInOneTransaction", () -> {
                    startPatch(restore);
                    operations.patchAll(run(), parameters.patchId(), parameters.planId(), restore);
                    finishPatch(restore);
                }))
                .next(external("exportPatchAudit", publish))
                .next(manifest())
                .build();
    }

    @Bean
    Job dataBackfill() {
        return job("DataBackfill")
                .start(step("freezeBackfillWork", () -> operations.freezeBackfill(scope(), parameters.recalculate())))
                .next(updateStep("applyBackfill", "DataBackfill", true))
                .next(step("verifyBackfill", () -> operations.verifyUpdates(run())))
                .build();
    }

    @Bean
    Job dataArchive() {
        return job("DataArchive")
                .start(step("freezeArchiveWork", () -> operations.freezeArchive(scope())))
                .next(external("archiveCustomersToS3", () -> exportWork("archive")))
                .next(external("confirmArchiveAndDeleteMatchingVersions", () -> {
                    // Recheck the stored object even when a restart skips the completed upload step.
                    exportWork("archive");
                    new TransactionTemplate(transactions).executeWithoutResult(ignored -> operations.deleteArchived(run()));
                }))
                .next(manifest())
                .build();
    }

    @Bean
    Job dataCleanup() {
        return job("DataCleanup")
                .start(step("removeExpiredCompletedRunWork", () -> operations.cleanup(run(), parameters.retainDays())))
                .build();
    }

    @Bean
    Job conditionalFlow() {
        JobExecutionDecider decide = (jobExecution, stepExecution) ->
                new FlowExecutionStatus(parameters.branch().equals("apply") ? "APPLY" : "PREVIEW");
        Step report = external("exportConditionalTargets", () -> exportWork("conditional"));
        return job("ConditionalFlow")
                .start(step("freezeConditionalWork", () -> operations.freezeStatus(scope())))
                .next(decide).on("APPLY")
                .to(step("applyConditionalStatus", () -> operations.updateAll(run(), false))).next(report)
                .from(decide).on("PREVIEW").to(report)
                .from(report).on("COMPLETED").to(manifest())
                .end().build();
    }

    @Bean
    Job masterSync(@Qualifier("stagedInputStep") Step stage, @Qualifier("validateInputStep") Step validate) {
        return job("MasterSync").start(stage)
                .next(validate)
                .next(step("freezeMasterChanges", () -> operations.freezeMasterSync(scope(), parameters.deleteMissing())))
                .next(step("reflectCompleteMaster", () -> operations.sync(run(), parameters.deleteMissing())))
                .build();
    }

    @Bean
    Job incrementalExport() {
        return job("IncrementalExport")
                .start(step("captureIncrementalInterval", () -> operations.freezeIncremental(scope(),
                        parameters.watermarkId(), parameters.overlapSeconds(), parameters.hasDateLimit())))
                .next(external("exportFixedIncrementalInterval", () -> exportWork("incremental")))
                .next(manifest())
                .next(step("advanceWatermarkAfterPublication", () -> operations.advanceWatermark(run())))
                .build();
    }

    private JobBuilder job(String name) {
        return new JobBuilder(name, jobRepository);
    }

    private Step step(String name, Action action) {
        return createStep(name, action, false);
    }

    private Step external(String name, Action action) {
        return createStep(name, action, true);
    }

    private Step createStep(String name, Action action, boolean external) {
        var builder = new StepBuilder(name, jobRepository)
                .tasklet(JobTasklets.interruptible(context, (contribution, chunkContext) -> {
                    action.run();
                    return RepeatStatus.FINISHED;
                }), transactions);
        if (external) {
            builder.transactionAttribute(JobTasklets.withoutTransaction());
        }
        return builder.build();
    }

    private Step manifest() {
        return external("publishOperationManifest", files::manifest);
    }

    private Step updateStep(String name, String job, boolean backfill) {
        if (!context.job().equals(job) || parameters.mode().equals("single")) {
            return step(name, () -> operations.updateAll(run(), backfill));
        }
        return new StepBuilder(name, jobRepository).<Long, Long>chunk(parameters.chunkSize())
                .transactionManager(transactions)
                .reader(new OperationPageReader<>(
                        after -> operations.operationIds(run(), after, parameters.chunkSize()), Long::longValue))
                .writer(chunk -> {
                    context.checkStop();
                    operations.updateChunk(run(), backfill, List.copyOf(chunk.getItems()));
                })
                .build();
    }

    private Step patchChunkStep(boolean restore) {
        return new StepBuilder("applyPatchInChunks", jobRepository).<Long, Long>chunk(parameters.chunkSize())
                .transactionManager(transactions)
                .reader(new OperationPageReader<>(
                        after -> operations.patchIds(parameters.planId(), after, parameters.chunkSize()), Long::longValue))
                .writer(chunk -> {
                    context.checkStop();
                    operations.patchChunk(run(), parameters.patchId(), parameters.planId(),
                            List.copyOf(chunk.getItems()), restore);
                })
                .build();
    }

    private void startPatch(boolean restore) {
        operations.startPatch(scope(), parameters.patchId(), parameters.planId(), parameters.mode(), restore);
    }

    private void finishPatch(boolean restore) {
        operations.finishPatch(run(), parameters.patchId(), parameters.planId(), restore);
    }

    private void exportPatchPreview() throws Exception {
        files.export("patch-preview", true, PATCH_PREVIEW_COLUMNS, sink -> {
            FileSettings format = files.output("patch-preview");
            operations.streamPatch(parameters.planId(), row -> sink.row(List.of(number(format, row.id()),
                    row.oldStatus(), row.newStatus(), number(format, row.oldVersion()))));
        });
    }

    private void exportAppliedPatch() throws Exception {
        files.export("patch-backup", true, PATCH_BACKUP_COLUMNS, sink -> {
            FileSettings format = files.output("patch-backup");
            operations.streamPatch(parameters.planId(), row -> sink.row(List.of(number(format, row.id()),
                    row.oldStatus(), number(format, row.oldVersion()))));
        });
        files.export("patch-diff", true, PATCH_DIFF_COLUMNS, sink -> {
            FileSettings format = files.output("patch-diff");
            operations.streamPatch(parameters.planId(), row -> sink.row(List.of(number(format, row.id()),
                    row.oldStatus(), row.newStatus(), number(format, row.oldVersion()), number(format, row.appliedVersion()))));
        });
    }

    private void exportRestoredPatch() throws Exception {
        files.export("patch-restore", true, PATCH_RESTORE_COLUMNS, sink -> {
            FileSettings format = files.output("patch-restore");
            operations.streamPatch(parameters.planId(), row -> sink.row(List.of(number(format, row.id()), row.oldStatus(),
                    number(format, row.appliedVersion()), number(format, row.restoredVersion()))));
        });
    }

    private void exportWork(String artifact) throws Exception {
        FileSettings format = files.output(artifact);
        files.export(artifact, true, CUSTOMER_COLUMNS, sink -> operations.streamWork(run(), row -> sink.row(Arrays.asList(
                number(format, row.id()), row.name(), row.email(), row.status(),
                timestamp(artifact, format, row.updatedAt()), number(format, row.version()), row.detail()))));
    }

    private String timestamp(String artifact, FileSettings format, OffsetDateTime timestamp) {
        if (context.fileOptions(artifact).containsKey("output.dateFormat")) {
            return format.dateFormatter().format(timestamp);
        }
        return timestamp.atZoneSameInstant(format.timeZone()).toOffsetDateTime().toString();
    }

    private static String number(FileSettings format, long value) {
        return format.formatNumber(BigDecimal.valueOf(value));
    }

    private MigrationTarget migrationTarget() {
        return new MigrationTarget(environment);
    }

    private RunKey run() {
        return new RunKey(context.job(), context.runId());
    }

    private Scope scope() {
        return parameters.scope(run());
    }

    @FunctionalInterface
    private interface Action {
        void run() throws Exception;
    }
}
