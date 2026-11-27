package cookbook.batch.examples.operations;

import java.time.LocalDate;
import java.time.OffsetDateTime;

public final class OperationModels {
    private OperationModels() {
    }

    public record RunKey(String job, String runId) {
    }

    public record Scope(
            RunKey run, long idFrom, long idTo, OffsetDateTime from, OffsetDateTime to,
            String status, String targetStatus, long maxRows, Long expectedRows) {
    }

    public record CustomerRow(long id, String name, String email, String status,
                              OffsetDateTime updatedAt, long version, String detail) {
    }

    public record SummaryPeriod(String period, LocalDate from, LocalDate to) {
    }

    public record PatchRequest(String patchId, String planId, Scope scope, String definition) {
    }

    public record PatchPlan(String patchId, String planId, String state, String definition, long expectedRows,
                            String previewRun, String applyRun, String restoreRun, String mode) {
    }

    public record PatchRow(long id, String oldStatus, String newStatus, long oldVersion,
                           Long appliedVersion, Long restoredVersion) {
    }

    public record Watermark(String id, OffsetDateTime lower, OffsetDateTime upper) {
    }
}
