package cookbook.batch.common;

import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Parses the non-option name=value arguments passed to one batch process. */
public record BatchArguments(String job, String runId, Map<String, String> values) {
    private static final Pattern JOB_NAME = Pattern.compile("[A-Za-z][A-Za-z0-9]{0,63}");
    private static final Set<String> SHARED_OPTIONS = Set.of(
            "sql.fromDate", "sql.toDate", "sql.status", "destinations", "fetchSize",
            "chunkSize", "partSize", "transferWorkers", "totalBuffers", "partitions",
            "patchId", "planId", "dryRun");
    private static final Set<String> FILE_OPTIONS = Set.of(
            "format", "compression", "charset", "header", "bom", "lineEnding", "delimiter",
            "quote", "escape", "nullValue", "columns", "columnNames", "dateFormat", "timeZone", "numberFormat",
            "gzipLevel", "maxColumns", "maxColumnChars", "maxRecordChars");

    public enum Destinations { INTERNAL, PARTNER, BOTH }

    public BatchArguments {
        if (job == null || !JOB_NAME.matcher(job).matches()) {
            throw new IllegalArgumentException("job must be a registered job name");
        }
        if (runId == null || runId.isBlank() || runId.length() > 128
                || runId.codePoints().anyMatch(Character::isISOControl)) {
            throw new IllegalArgumentException("runId must contain 1 to 128 non-control characters");
        }
        values = Map.copyOf(values);
    }

    public static BatchArguments parse(String[] args, Set<String> jobOptionNames) {
        return parse(List.of(args), jobOptionNames);
    }

    public static BatchArguments parse(List<String> args, Set<String> jobOptionNames) {
        Set<String> allowed = allowedOptions(jobOptionNames);
        allowed.add("job");
        allowed.add("runId");
        Map<String, String> parameters = new HashMap<>();
        for (String argument : args) {
            int separator = argument.indexOf('=');
            if (separator <= 0) {
                throw new IllegalArgumentException("expected non-option arguments in name=value form");
            }
            String name = argument.substring(0, separator);
            if (!allowed.contains(name)) {
                throw new IllegalArgumentException("unknown job argument name");
            }
            if (parameters.putIfAbsent(name, argument.substring(separator + 1)) != null) {
                throw new IllegalArgumentException("duplicate job argument: " + name);
            }
        }
        String job = parameters.remove("job");
        String runId = parameters.remove("runId");
        BatchArguments parsed = new BatchArguments(job, runId, parameters);
        parsed.validateSharedOptions();
        return parsed;
    }

    public static void validateOptionNames(Set<String> names, Set<String> jobOptionNames) {
        if (!allowedOptions(jobOptionNames).containsAll(names)) {
            throw new IllegalArgumentException("Unknown key in cookbook.batch job or file settings");
        }
    }

    private static Set<String> allowedOptions(Set<String> jobOptionNames) {
        Set<String> allowed = new HashSet<>(SHARED_OPTIONS);
        allowed.addAll(jobOptionNames);
        for (String option : FILE_OPTIONS) {
            allowed.add("input." + option);
            allowed.add("output." + option);
        }
        return allowed;
    }

    public BatchArguments withValues(Map<String, String> resolvedValues) {
        BatchArguments resolved = new BatchArguments(job, runId, resolvedValues);
        resolved.validateSharedOptions();
        return resolved;
    }

    public String value(String key, String fallback) {
        return values.getOrDefault(key, fallback);
    }

    public String require(String key) {
        String value = values.get(key);
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(key + " is required");
        }
        return value;
    }

    public int integer(String key, int fallback, int minimum, int maximum) {
        String value = values.get(key);
        if (value == null) {
            return fallback;
        }
        final int number;
        try {
            number = Integer.parseInt(value);
        } catch (NumberFormatException invalid) {
            throw new IllegalArgumentException(key + " must be an integer");
        }
        if (number < minimum || number > maximum) {
            throw new IllegalArgumentException(key + " must be between " + minimum + " and " + maximum);
        }
        return number;
    }

    public boolean bool(String key, boolean fallback) {
        String value = values.get(key);
        if (value == null) {
            return fallback;
        }
        return switch (value.toLowerCase(Locale.ROOT)) {
            case "true" -> true;
            case "false" -> false;
            default -> throw new IllegalArgumentException(key + " must be true or false");
        };
    }

    public LocalDate date(String key) {
        String value = values.get(key);
        if (value == null) {
            return null;
        }
        try {
            return LocalDate.parse(value);
        } catch (DateTimeParseException invalid) {
            throw new IllegalArgumentException(key + " must be an ISO date");
        }
    }

    public LocalDate fromDate() {
        return date("sql.fromDate");
    }

    public LocalDate toDate() {
        return date("sql.toDate");
    }

    public String status() {
        return values.get("sql.status");
    }

    public Destinations destinations() {
        try {
            return Destinations.valueOf(value("destinations", "internal").toUpperCase(Locale.ROOT));
        } catch (IllegalArgumentException invalid) {
            throw new IllegalArgumentException("destinations must be internal, partner, or both");
        }
    }

    @Override
    public String toString() {
        return "BatchArguments[job=" + job + ", runId=" + runId + "]";
    }

    private void validateSharedOptions() {
        LocalDate start = fromDate();
        LocalDate end = toDate();
        if (start != null && end != null && end.isBefore(start)) {
            throw new IllegalArgumentException("sql.toDate precedes sql.fromDate");
        }
        if (status() != null && (status().isBlank() || status().length() > 32)) {
            throw new IllegalArgumentException("sql.status must have 1 to 32 characters");
        }
        destinations();
        bool("dryRun", true);
        integer("fetchSize", 1_000, 1, 100_000);
        integer("chunkSize", 1_000, 1, 100_000);
        integer("partSize", 8 * 1024 * 1024, 5 * 1024 * 1024, 128 * 1024 * 1024);
        integer("transferWorkers", 1, 1, 32);
        integer("totalBuffers", 2, 1, 128);
        integer("partitions", 1, 1, 256);
    }
}
