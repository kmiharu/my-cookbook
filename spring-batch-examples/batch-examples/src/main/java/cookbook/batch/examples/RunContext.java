package cookbook.batch.examples;

import cookbook.batch.common.BatchArguments;
import cookbook.batch.common.BatchProperties;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

public record RunContext(BatchArguments args, Map<String, String> options, String job,
                         BatchArguments raw, BatchProperties properties, AtomicBoolean stopping) {
    public RunContext(BatchArguments raw, BatchProperties properties, String job) {
        this(raw.withValues(properties.resolve(raw, null)), properties.resolve(raw, null), job, raw, properties,
                new AtomicBoolean());
    }

    public Map<String, String> fileOptions(String file) {
        return properties.resolve(raw, file);
    }

    public String runId() {
        return args.runId();
    }

    public String value(String name, String fallback) {
        return options.getOrDefault(name, fallback);
    }

    public int integer(String name, int fallback, int min, int max) {
        return (int) number(name, fallback, min, max);
    }

    public long number(String name, long fallback, long min, long max) {
        String input = value(name, Long.toString(fallback));
        try {
            long value = Long.parseLong(input);
            if (value >= min && value <= max) {
                return value;
            }
        } catch (NumberFormatException ignored) {
            // Report a single error for malformed and out-of-range options.
        }
        throw new IllegalArgumentException(name + " must be between " + min + " and " + max);
    }

    public boolean flag(String name, boolean fallback) {
        return switch (value(name, Boolean.toString(fallback))) {
            case "true" -> true;
            case "false" -> false;
            default -> throw new IllegalArgumentException(name + " must be true or false");
        };
    }

    public CustomerConditions conditions() {
        String from = value("sql.fromDate", null);
        String to = value("sql.toDate", null);
        var lower = from == null ? null : LocalDate.parse(from).atStartOfDay().atOffset(ZoneOffset.UTC);
        var upper = to == null ? null : LocalDate.parse(to).atStartOfDay().atOffset(ZoneOffset.UTC);
        if (lower != null && upper != null && !lower.isBefore(upper)) {
            throw new IllegalArgumentException("sql.fromDate must precede sql.toDate");
        }
        return new CustomerConditions(lower, upper, value("sql.status", null));
    }

    public int fetchSize() {
        return integer("fetchSize", 1000, 1, 10000);
    }

    public int chunkSize() {
        return integer("chunkSize", 1000, 1, 10000);
    }

    public int partitions() {
        return integer("partitions", 1, 1, 8);
    }

    public void checkStop() throws InterruptedException {
        if (stopping.get() || Thread.currentThread().isInterrupted()) {
            throw new InterruptedException("Stop requested");
        }
    }
}
