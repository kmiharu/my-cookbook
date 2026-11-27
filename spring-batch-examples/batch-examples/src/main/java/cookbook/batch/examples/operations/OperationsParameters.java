package cookbook.batch.examples.operations;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.Set;

import static cookbook.batch.examples.operations.OperationModels.*;

public final class OperationsParameters {
    private static final Set<String> RANGE = Set.of(
            "idFrom", "idTo", "sql.fromDate", "sql.toDate", "sql.status", "maxRows", "expectedRows");
    private static final Set<String> PATCH = Set.of("patchId", "planId", "dryRun", "mode", "maxRows", "expectedRows");
    private static final Map<String, Set<String>> JOB_OPTIONS = Map.ofEntries(
            Map.entry("CustomerDelete", Set.of("maxRows", "expectedRows")),
            Map.entry("DataTransform", RANGE),
            Map.entry("Aggregation", Set.of("period", "sql.fromDate", "sql.toDate")),
            Map.entry("StatusUpdate", Set.of("targetStatus")),
            Map.entry("BulkUpdate", Set.of("targetStatus", "mode")),
            Map.entry("DataReconciliation", Set.of("maxRows")),
            Map.entry("DataMigration", RANGE),
            Map.entry("DataPatchPreview", PATCH),
            Map.entry("DataPatchApply", PATCH),
            Map.entry("DataPatchRestore", PATCH),
            Map.entry("DataBackfill", Set.of("mode", "recalculate")),
            Map.entry("DataArchive", RANGE),
            Map.entry("DataCleanup", Set.of("retainDays")),
            Map.entry("ConditionalFlow", Set.of("branch", "targetStatus")),
            Map.entry("MasterSync", Set.of("deleteMissing", "maxRows", "expectedRows")),
            Map.entry("IncrementalExport", Set.of("watermarkId", "overlapSeconds", "sql.fromDate", "sql.toDate", "maxRows")));

    private static final LocalDate DEFAULT_FROM = LocalDate.of(2000, 1, 1);
    private static final LocalDate DEFAULT_TO = LocalDate.of(2100, 1, 1);
    private final Map<String, String> options;

    public OperationsParameters(Map<String, String> options) {
        this.options = options;
    }

    public static boolean accepts(String job, String key) {
        return JOB_OPTIONS.getOrDefault(job, Set.of()).contains(key)
                || ((job.equals("StatusUpdate") || job.equals("BulkUpdate") || job.equals("ConditionalFlow")
                      || job.equals("DataBackfill") || job.equals("DataPatchPreview")) && RANGE.contains(key))
                || (job.equals("DataPatchPreview") && key.equals("targetStatus"));
    }

    public void validate(String job) {
        if (!JOB_OPTIONS.containsKey(job)) {
            return;
        }
        scope(new RunKey(job, "validation"));
        if (options.containsKey("mode")) {
            mode();
        }
        if (options.containsKey("branch")) {
            branch();
        }
        if (options.containsKey("deleteMissing") && deleteMissing() && !hasInputCompletenessEvidence()) {
            throw new IllegalArgumentException("Master deletion requires input.rows and input.sha256 for every input");
        }
        if (options.containsKey("recalculate")) {
            recalculate();
        }
        if (options.containsKey("dryRun")) {
            boolean dryRun = bool("dryRun");
            if (job.equals("DataPatchPreview") != dryRun) {
                throw new IllegalArgumentException("dryRun does not match the selected patch phase");
            }
        }
        if (job.startsWith("DataPatch")) {
            patchId();
            planId();
        }
        if (job.equals("Aggregation")) {
            period();
        }
        if (job.equals("IncrementalExport")) {
            watermarkId();
            overlapSeconds();
        }
        if (job.equals("DataCleanup")) {
            retainDays();
        }
    }

    public Scope scope(RunKey run) {
        long first = number("idFrom", 1L, 1L, Long.MAX_VALUE);
        long last = number("idTo", Long.MAX_VALUE, 1L, Long.MAX_VALUE);
        OffsetDateTime from = date("sql.fromDate", DEFAULT_FROM).atStartOfDay().atOffset(ZoneOffset.UTC);
        OffsetDateTime to = date("sql.toDate", DEFAULT_TO).atStartOfDay().atOffset(ZoneOffset.UTC);
        long defaultMaxRows = switch (run.job()) {
            case "DataTransform", "DataReconciliation", "DataMigration", "DataArchive", "IncrementalExport",
                 "BulkUpdate", "DataBackfill" -> 10_000_000L;
            default -> 1_000L;
        };
        long maxRows = number("maxRows", defaultMaxRows, 0L, 100_000_000L);
        Long expectedRows = options.containsKey("expectedRows")
                ? number("expectedRows", 0L, 0L, maxRows)
                : null;
        if (first > last || !from.isBefore(to)) {
            throw new IllegalArgumentException("The customer ID or update date range is reversed or empty");
        }
        return new Scope(run, first, last, from, to, text("sql.status", null, 64),
                text("targetStatus", "ACTIVE", 64), maxRows, expectedRows);
    }

    public SummaryPeriod period() {
        String period = select("period", "day", Set.of("day", "month"));
        LocalDate from = date("sql.fromDate", DEFAULT_FROM);
        LocalDate to = date("sql.toDate", DEFAULT_TO);
        if (period.equals("month") && (from.getDayOfMonth() != 1 || to.getDayOfMonth() != 1)) {
            throw new IllegalArgumentException("Monthly aggregation dates must be the first day of each month");
        }
        return new SummaryPeriod(period, from, to);
    }

    public String patchId() {
        return text("patchId", null, 100, true);
    }

    public String planId() {
        return text("planId", null, 100, true);
    }

    public String mode() {
        return select("mode", "single", Set.of("single", "chunk"));
    }

    public String branch() {
        return select("branch", "preview", Set.of("preview", "apply"));
    }

    public boolean deleteMissing() {
        return bool("deleteMissing");
    }

    public boolean recalculate() {
        return bool("recalculate");
    }

    public long overlapSeconds() {
        return number("overlapSeconds", 900, 0, 31_536_000);
    }

    public String watermarkId() {
        return text("watermarkId", "customers", 100);
    }

    public long retainDays() {
        return number("retainDays", 30, 1, 3_650);
    }

    public int chunkSize() {
        return Math.toIntExact(number("chunkSize", 1000, 1, 10_000));
    }

    public boolean hasDateLimit() {
        return options.containsKey("sql.toDate");
    }

    public boolean hasInputCompletenessEvidence() {
        return !options.getOrDefault("input.rows", "").isBlank() && !options.getOrDefault("input.sha256", "").isBlank();
    }

    private long number(String key, long fallback, long min, long max) {
        String value = options.get(key);
        long number = value == null ? fallback : Long.parseLong(value);
        if (number < min || number > max) {
            throw new IllegalArgumentException(key + " must be between " + min + " and " + max);
        }
        return number;
    }

    private LocalDate date(String key, LocalDate fallback) {
        String value = options.get(key);
        return value == null ? fallback : LocalDate.parse(value);
    }

    private boolean bool(String key) {
        String value = options.getOrDefault(key, "false");
        if (!value.equals("true") && !value.equals("false")) {
            throw new IllegalArgumentException(key + " must be true or false");
        }
        return Boolean.parseBoolean(value);
    }

    private String select(String key, String fallback, Set<String> allowed) {
        String value = options.getOrDefault(key, fallback);
        if (!allowed.contains(value)) {
            throw new IllegalArgumentException(key + " has an unsupported value");
        }
        return value;
    }

    private String text(String key, String fallback, int limit) {
        return text(key, fallback, limit, false);
    }

    private String text(String key, String fallback, int limit, boolean required) {
        String value = options.getOrDefault(key, fallback);
        if ((value == null && required) || (value != null && (value.isBlank() || value.length() > limit))) {
            throw new IllegalArgumentException(key + " must be nonempty and at most " + limit + " characters");
        }
        return value;
    }
}
