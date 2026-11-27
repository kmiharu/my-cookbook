package cookbook.batch.common;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.MapConfigurationPropertySource;

class BatchArgumentsTest {
    @Test
    void parsesTypedOptionsAndPreservesRunIdentifier() {
        BatchArguments args = BatchArguments.parse(List.of(
                "job=CustomerExport", "runId=顧客 'run'", "destinations=both",
                "sql.fromDate=2024-02-29", "sql.toDate=2024-03-01", "inputKey=data/a=b.csv"), Set.of("inputKey"));
        assertEquals("顧客 'run'", args.runId());
        assertEquals(BatchArguments.Destinations.BOTH, args.destinations());
        assertEquals(LocalDate.of(2024, 2, 29), args.fromDate());
        assertEquals("data/a=b.csv", args.value("inputKey", null));
        assertFalse(args.toString().contains("data/a=b.csv"));
    }

    @Test
    void validatesKnownTypedOptionsBeforeLaunch() {
        BatchArguments.validateOptionNames(Set.of("output.columnNames", "input.key"), Set.of("input.key"));
        assertThrows(IllegalArgumentException.class,
                () -> BatchArguments.validateOptionNames(Set.of("output.header", "password"), Set.of()));
        for (String option : List.of("password=secret", "job=Other", "fetchSize=0", "dryRun=yes",
                "destinations=third", "runId=duplicate", "sql.fromDate=2024-02-30",
                "--spring.profiles.active=local")) {
            assertThrows(IllegalArgumentException.class, () -> BatchArguments.parse(
                    List.of("job=CustomerExport", "runId=example", option), Set.of()));
        }
        assertThrows(IllegalArgumentException.class, () -> BatchArguments.parse(
                List.of("job=CustomerExport", "runId=example", "sql.fromDate=2025-01-02", "sql.toDate=2025-01-01"), Set.of()));
    }

    @Test
    void resolvesCommonJobFileAndRuntimeOptionsInOrder() {
        BatchProperties properties = new BatchProperties(Map.of("output.format", "csv", "output.header", "true"),
                Map.of("CustomerExport", new BatchProperties.JobSettings(
                        Map.of("output.format", "tsv", "output.compression", "gzip"),
                        Map.of("members", Map.of("output.header", "false", "output.compression", "none")))));
        BatchArguments args = BatchArguments.parse(List.of("job=CustomerExport", "runId=x",
                "output.format=csv"), Set.of());
        assertEquals(Map.of("output.format", "csv", "output.header", "false", "output.compression", "none"),
                properties.resolve(args, "members"));
        assertEquals("gzip", properties.resolve(args, null).get("output.compression"));
    }

    @Test
    void springBinderKeepsCaseSensitiveJobNamesAndDottedOptionKeys() {
        Map<String, String> yamlProperties = Map.of(
                "cookbook.batch.defaults[output.format]", "csv",
                "cookbook.batch.jobs[CustomerExport].options[output.format]", "tsv",
                "cookbook.batch.jobs[CustomerExport].files[members][output.header]", "false");
        BatchProperties properties = new Binder(new MapConfigurationPropertySource(yamlProperties))
                .bind("cookbook.batch", BatchProperties.class)
                .orElseThrow(AssertionError::new);
        BatchArguments args = BatchArguments.parse(List.of("job=CustomerExport", "runId=x"), Set.of());
        assertEquals(Map.of("output.format", "tsv", "output.header", "false"), properties.resolve(args, "members"));
    }
}
