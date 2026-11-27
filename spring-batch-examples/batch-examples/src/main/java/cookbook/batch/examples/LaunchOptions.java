package cookbook.batch.examples;

import cookbook.batch.common.BatchArguments;
import cookbook.batch.file.FileSettings;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.Set;

final class LaunchOptions {
    static final Set<String> EXTRA = Set.of(
            "input.key", "input.keys", "input.sha256", "input.rows", "input.readyKey",
            "arrivalTimeoutSeconds", "skipLimit", "rows", "rowWidth", "seed", "startId", "mode",
            "patchId", "planId", "dryRun", "targetStatus", "maxRows", "expectedRows", "idFrom", "idTo",
            "period", "deleteMissing", "overlapSeconds", "watermarkId", "retainDays", "branch",
            "dynamo.partition", "dynamo.gsi", "dynamo.status", "dynamo.pageLimit", "dynamo.batchSize",
            "dynamo.workers", "dynamo.rateLimit", "dynamo.readMode", "dynamo.consistentRead", "dynamo.writeMode",
            "dynamo.operation", "dynamo.targetPartition", "dynamo.retryAttempts",
            "dynamo.retrySeconds", "dynamo.expectedItems", "recover.executionId", "recover.owner", "transferMode", "recalculate");
    private static final Set<String> INPUT_JOBS = Set.of(
            "CustomerImport", "CustomerUpsert", "CustomerDelete", "ValidatedImport", "MultiFileImport",
            "ImportAndExport", "DataReconciliation", "SkipRecord", "Restartable", "FileArrivalCheck",
            "MasterSync", "FileTransfer", "ChecksumValidation", "CopyImport", "ChunkSizeBenchmark",
            "DynamoDbImport", "DynamoDbConditionalUpdate", "DynamoDbDelete");
    private static final Set<String> JOBS = Set.of(
            "Migrate", "Seed", "CustomerExport", "WorkTableExport", "MultiFileExport", "CustomerImport",
            "CustomerUpsert", "CustomerDelete", "ValidatedImport", "MultiFileImport", "DataTransform",
            "Aggregation", "StatusUpdate", "BulkUpdate", "ImportAndExport", "DataReconciliation", "DataMigration",
            "DataPatchPreview", "DataPatchApply", "DataPatchRestore", "DataBackfill", "DataArchive", "DataCleanup",
            "ConditionalFlow", "ParallelStep", "Partitioned", "Retry", "SkipRecord", "Restartable",
            "FileArrivalCheck", "MasterSync", "IncrementalExport", "FullExport", "FileTransfer",
            "ChecksumValidation", "SqlOptimization", "IndexOptimization", "FetchSizeBenchmark",
            "BatchInsertBenchmark", "CopyExport", "CopyImport", "ParallelMultipartUpload", "PartitionBenchmark",
            "GzipBenchmark", "ChunkSizeBenchmark", "DynamoDbQueryExport", "DynamoDbScanExport",
            "DynamoDbImport", "DynamoDbConditionalUpdate", "DynamoDbDelete", "PostgreSqlToDynamoDb",
            "DynamoDbToPostgreSql", "DynamoDbBenchmark");

    private LaunchOptions() {}

    static String jobName(BatchArguments args) {
        String job = args.job().equals("DataPatch")
                ? args.bool("dryRun", true) ? "DataPatchPreview" : "DataPatchApply"
                : args.job();
        if (!JOBS.contains(job)) {
            throw new IllegalArgumentException("Unknown batch job");
        }
        return job;
    }

    static boolean needsInput(String job) {
        return INPUT_JOBS.contains(job);
    }

    static void validate(RunContext run) {
        for (String key : run.raw().values().keySet()) {
            if (EXTRA.contains(key) && !jobSupports(run.job(), key)) {
                throw new IllegalArgumentException("Option " + key + " is unavailable for " + run.job());
            }
        }
        validateHeaderOptions(run);
        for (var file : run.properties().jobs().getOrDefault(run.raw().job(),
                new cookbook.batch.common.BatchProperties.JobSettings(null, null)).files().values()) {
            if (file.keySet().stream().anyMatch(key -> !key.startsWith("input.") && !key.startsWith("output."))) {
                throw new IllegalArgumentException("File options must use the input or output prefix");
            }
        }
        var operations = new cookbook.batch.examples.operations.OperationsParameters(run.options());
        operations.validate(run.job());
        cookbook.batch.examples.operations.OperationsJobs.validateFileOptions(run);
        if (cookbook.batch.examples.dynamo.DynamoJobs.JOBS.contains(run.job())) {
            cookbook.batch.examples.dynamo.DynamoJobs.validate(run);
        }
        run.conditions();
        run.fetchSize();
        run.chunkSize();
        int readers = switch (run.job()) {
            case "Partitioned", "PartitionBenchmark" -> run.partitions();
            case "ParallelStep" -> 2;
            default -> 1;
        };
        if ((long) readers * run.fetchSize() * 22 * 1024 > 224L * 1024 * 1024) {
            throw new IllegalArgumentException("Concurrent fetch windows exceed the cursor data budget");
        }
        FileSettings input = FileSettings.from(run.options(), "input");
        FileSettings output = FileSettings.from(run.options(), "output");
        if (run.job().equals("CopyExport")) {
            validateCopy(output);
        }
        if (run.job().equals("CopyImport")) {
            validateCopy(input);
        }
        if (needsInput(run.job())) {
            validateInput(run);
        }
        run.integer("skipLimit", 0, 0, 10000);
        if (run.job().equals("BatchInsertBenchmark") &&
                !Set.of("sequential", "batch", "rewrite").contains(run.value("mode", "batch"))) {
            throw new IllegalArgumentException("mode must be sequential, batch or rewrite");
        }
        if (run.job().equals("FileTransfer") &&
                !Set.of("stream", "copy").contains(run.value("transferMode", "stream"))) {
            throw new IllegalArgumentException("transferMode must be stream or copy");
        }
        if (run.job().equals("Seed") || run.job().equals("BatchInsertBenchmark")) {
            run.number("rows", 100, 0, 10_000_000);
            run.number("startId", 1, 1, 1_000_000_000_000L);
            run.integer("rowWidth", 256, 64, 4096);
            run.integer("seed", 31, 1, 10000);
        }
        if (run.options().containsKey("recover.executionId") != run.options().containsKey("recover.owner")) {
            throw new IllegalArgumentException("Recovery requires both execution ID and verified stopped owner");
        }
        if ((long) input.maxRecordChars() * run.chunkSize() > 64L * 1024 * 1024) {
            throw new IllegalArgumentException("chunkSize multiplied by input.maxRecordChars exceeds the input budget");
        }
    }

    private static void validateHeaderOptions(RunContext run) {
        var settingMaps = new java.util.ArrayList<java.util.Map<String, String>>();
        settingMaps.add(run.options());
        var jobSettings = run.properties().jobs().get(run.raw().job());
        if (jobSettings != null) {
            for (String name : jobSettings.files().keySet()) {
                settingMaps.add(run.fileOptions(name));
            }
        }
        for (var settings : settingMaps) {
            BatchArguments.validateOptionNames(settings.keySet(), EXTRA);
            for (String type : List.of("input", "output")) {
                FileSettings file = FileSettings.from(settings, type);
                if (!file.columnNames().isEmpty() && file.columns().isEmpty()) {
                    throw new IllegalArgumentException(type + ".columnNames requires an explicit column order");
                }
            }
        }
    }

    private static boolean jobSupports(String job, String key) {
        if (key.startsWith("input.")) {
            return needsInput(job);
        }
        if (key.startsWith("recover.")) {
            return !job.equals("Migrate");
        }
        if (key.startsWith("dynamo.")) {
            return cookbook.batch.examples.dynamo.DynamoJobs.JOBS.contains(job)
                    && cookbook.batch.examples.dynamo.DynamoJobs.OPTIONS.contains(key);
        }
        if (cookbook.batch.examples.operations.OperationsParameters.accepts(job, key)) {
            return true;
        }
        return switch (key) {
            case "arrivalTimeoutSeconds", "skipLimit" -> needsInput(job);
            case "rows" -> Set.of("Seed", "BatchInsertBenchmark", "IndexOptimization").contains(job);
            case "rowWidth", "seed", "startId" -> Set.of("Seed", "BatchInsertBenchmark").contains(job);
            case "mode" -> job.equals("BatchInsertBenchmark");
            case "transferMode" -> job.equals("FileTransfer");
            default -> false;
        };
    }

    private static void validateInput(RunContext run) {
        String key = run.value("input.key", "");
        String keys = run.value("input.keys", "");
        if (key.isEmpty() == keys.isEmpty()) {
            throw new IllegalArgumentException("Specify either input.key or input.keys");
        }
        List<String> names = List.of((key.isEmpty() ? keys : key).split(",", -1));
        if (names.size() > 32 || names.stream().anyMatch(String::isBlank)
                || names.stream().distinct().count() != names.size()) {
            throw new IllegalArgumentException("Input must contain distinct nonblank object keys (maximum 32)");
        }
        if (Set.of("FileTransfer", "CopyImport", "DynamoDbImport", "DynamoDbConditionalUpdate", "DynamoDbDelete")
                .contains(run.job()) && names.size() != 1) {
            throw new IllegalArgumentException("This job accepts exactly one input object");
        }
        String[] sha = run.value("input.sha256", "").split(",", -1);
        if (sha.length != names.size() || java.util.Arrays.stream(sha)
                .anyMatch(x -> !x.toLowerCase(Locale.ROOT).matches("[0-9a-f]{64}"))) {
            throw new IllegalArgumentException("Specify one valid input.sha256 for each input");
        }
        if (!Set.of("FileTransfer", "FileArrivalCheck").contains(run.job())) {
            String[] rows = run.value("input.rows", "").split(",", -1);
            if (rows.length != names.size()) {
                throw new IllegalArgumentException("Specify input.rows for each input");
            }
            for (String value : rows) {
                if (!value.matches("[0-9]{1,18}")) {
                    throw new IllegalArgumentException("input.rows must be a nonnegative logical record count");
                }
            }
        }
        run.integer("arrivalTimeoutSeconds", 0, 0, 600);
        for (int i = 1; i <= names.size(); i++) {
            FileSettings spec = FileSettings.from(run.fileOptions("input-" + i), "input");
            if (run.job().equals("CopyImport")) {
                validateCopy(spec);
            }
            if ((long) spec.maxRecordChars() * run.chunkSize() > 64L * 1024 * 1024) {
                throw new IllegalArgumentException("Input file settings exceed the chunk budget");
            }
        }
    }

    static void validateCopy(FileSettings file) {
        if (!file.charset().equals(StandardCharsets.UTF_8) || file.bom() ||
                file.lineEnding() != FileSettings.LineEnding.LF || file.quote() != '"'
                || file.escape() != FileSettings.Escape.DOUBLE_QUOTE || !file.nullValue().isEmpty()
                || file.delimiter() != (file.format() == FileSettings.Format.CSV ? ',' : '\t')
                || !file.columns().isEmpty() || !file.columnNames().isEmpty()) {
            throw new IllegalArgumentException("COPY requires UTF-8, LF, standard CSV/TSV, and the default columns");
        }
    }
}
