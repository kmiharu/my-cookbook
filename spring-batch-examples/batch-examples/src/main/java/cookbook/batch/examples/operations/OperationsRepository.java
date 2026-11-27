package cookbook.batch.examples.operations;

import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.OffsetDateTime;
import java.util.HexFormat;
import java.util.List;

import org.apache.ibatis.cursor.Cursor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import static cookbook.batch.examples.operations.OperationModels.*;

@Repository
public class OperationsRepository {
    private static final Logger log = LoggerFactory.getLogger(OperationsRepository.class);
    private static final String PATCH_DEFINITION = patchDefinition();
    private final OperationsMapper mapper;
    private final TransactionTemplate readTransaction;

    public OperationsRepository(OperationsMapper mapper, PlatformTransactionManager transactions) {
        this.mapper = mapper;
        this.readTransaction = new TransactionTemplate(transactions);
        this.readTransaction.setReadOnly(true);
    }

    public void freeze(Scope scope) {
        checkedCount(scope, mapper.freeze(scope, scope.maxRows() + 1));
    }

    public void transform(RunKey run) {
        exact(mapper.countWork(run), mapper.transform(run), "Work transformation");
    }

    public void freezeStatus(Scope scope) {
        checkedCount(scope, mapper.freezeStatus(scope, scope.maxRows() + 1));
    }

    public void freezeBackfill(Scope scope, boolean recalculate) {
        checkedCount(scope, mapper.freezeBackfill(scope, scope.maxRows() + 1, recalculate));
    }

    public void updateAll(RunKey run, boolean backfill) {
        long pending = mapper.countWork(run) - mapper.countApplied(run);
        exact(pending, update(run, backfill, null), "Customer update");
    }

    public void updateChunk(RunKey run, boolean backfill, List<Long> ids) {
        exact(ids.size(), update(run, backfill, ids), "Customer update");
    }

    public void verifyUpdates(RunKey run) {
        long applied = mapper.countApplied(run);
        exact(mapper.countWork(run), applied, "Recorded customer updates");
        log.info("verified updatedRows={}", applied);
    }

    private long update(RunKey run, boolean backfill, List<Long> ids) {
        return backfill ? mapper.updateEmail(run, ids) : mapper.updateStatus(run, ids);
    }

    public void aggregate(SummaryPeriod period) {
        mapper.lockAggregation(period.period());
        long replaced = mapper.clearAggregation(period);
        long totals = mapper.writeAggregation(period);
        log.info("period={} replacedTotals={} insertedTotals={}", period.period(), replaced, totals);
    }

    public void freezeDeletes(Scope scope) {
        long inputs = mapper.countInputs(scope.run());
        checkedCount(scope, inputs);
        exact(inputs, mapper.freezeDeletes(scope, scope.maxRows() + 1), "Matching input keys and versions");
    }

    public void deleteFrozen(RunKey run) {
        long pending = mapper.countWork(run) - mapper.countApplied(run);
        exact(pending, mapper.deleteFrozen(run, false), "Version-matched delete");
        log.info("versionMatchedDeletes={}", pending);
    }

    public void reconcile(Scope scope) {
        checkedCount(scope, mapper.freezeReconciliation(scope, scope.maxRows() + 1));
    }

    public void freezeMasterSync(Scope scope, boolean deleteMissing) {
        long count = mapper.countInputs(scope.run());
        checkedCount(scope, count);
        if (deleteMissing) {
            exact(0, mapper.countInputErrors(scope.run()), "Full master input errors");
            exact(mapper.countValidatedInputRows(scope.run()), count, "Staged full master rows");
        }
        Scope changes = new Scope(scope.run(), scope.idFrom(), scope.idTo(), scope.from(), scope.to(),
                scope.status(), scope.targetStatus(), scope.maxRows(), null);
        reconcile(changes);
    }

    public void freezeArchive(Scope scope) {
        freeze(scope);
        exact(0, mapper.countArchivedMemberships(scope.run()), "Dependencies outside the customer archive");
    }

    public void deleteArchived(RunKey run) {
        long pending = mapper.countWork(run) - mapper.countApplied(run);
        // A parent row lock also serializes FK checks for new memberships before this delete.
        exact(pending, mapper.lockArchiveCustomers(run), "Existing frozen customers");
        exact(0, mapper.countArchivedMemberships(run), "Dependencies outside the customer archive");
        deleteFrozen(run);
    }

    public void applyInputDeletes(RunKey run) {
        claimInput(run);
        deleteFrozen(run);
    }

    private void claimInput(RunKey run) {
        exact(mapper.countInputFiles(run), mapper.claimInput(run), "Unapplied input revisions");
    }

    public void sync(RunKey run, boolean deleteMissing) {
        claimInput(run);
        exact(mapper.countKind(run, "NEW"), mapper.insertReconciled(run), "Master inserts");
        exact(mapper.countKind(run, "CHANGED"), mapper.updateReconciled(run), "Master updates");
        if (deleteMissing) {
            exact(mapper.countKind(run, "MISSING"), mapper.deleteFrozen(run, true), "Master deletes");
        }
    }

    public void previewPatch(Scope scope, String patchId, String planId) {
        PatchRequest request = new PatchRequest(patchId, planId, scope, PATCH_DEFINITION);
        exact(1, mapper.createPatch(request), "New patch plan");
        long count = mapper.freezePatch(request, scope.maxRows() + 1);
        checkedCount(scope, count);
        exact(1, mapper.setPatchCount(planId, count), "Plan row count");
    }

    public void startPatch(Scope scope, String patchId, String planId, String mode, boolean restore) {
        PatchPlan plan = patchPlan(planId, patchId);
        checkedCount(scope, plan.expectedRows());
        if (restore) {
            if (!plan.state().equals("APPLIED")) {
                throw new IllegalStateException("Patch must be APPLIED before restore");
            }
            exact(1, mapper.startRestore(planId, scope.run().runId(), mode), "Restore plan claim");
        } else {
            if (!plan.state().equals("PREVIEWED")) {
                throw new IllegalStateException("Patch must be PREVIEWED before apply");
            }
            exact(1, mapper.claimPatch(patchId, planId), "Unused patch ID");
            exact(1, mapper.startApply(planId, scope.run().runId(), mode), "Apply plan claim");
        }
    }

    public void patchAll(RunKey run, String patchId, String planId, boolean restore) {
        PatchPlan plan = activePatch(run, patchId, planId, restore);
        exact(plan.expectedRows(), patchRows(planId, null, restore), "Patch affected rows");
    }

    public void patchChunk(RunKey run, String patchId, String planId, List<Long> ids, boolean restore) {
        activePatch(run, patchId, planId, restore);
        exact(ids.size(), patchRows(planId, ids, restore), "Patch affected rows");
    }

    private long patchRows(String planId, List<Long> ids, boolean restore) {
        return restore ? mapper.restorePatch(planId, ids) : mapper.applyPatch(planId, ids);
    }

    public void finishPatch(RunKey run, String patchId, String planId, boolean restore) {
        PatchPlan plan = activePatch(run, patchId, planId, restore);
        exact(plan.expectedRows(), mapper.patchResultCount(planId, restore), "Committed patch rows");
        String state = restore ? "RESTORED" : "APPLIED";
        exact(1, mapper.finishPatch(planId, state, plan.state()), "Patch final state");
        log.info("planId={} state={} verifiedRows={}", planId, state, plan.expectedRows());
    }

    private PatchPlan activePatch(RunKey run, String patchId, String planId, boolean restore) {
        PatchPlan plan = patchPlan(planId, patchId);
        String owner = restore ? plan.restoreRun() : plan.applyRun();
        String state = restore ? "RESTORING" : "APPLYING";
        if (!state.equals(plan.state()) || !run.runId().equals(owner)) {
            throw new IllegalStateException("Patch phase is not owned by this run");
        }
        return plan;
    }

    private PatchPlan patchPlan(String planId, String patchId) {
        PatchPlan plan = mapper.lockPatch(planId);
        if (plan == null || !plan.patchId().equals(patchId) || !plan.definition().equals(PATCH_DEFINITION)) {
            throw new IllegalStateException("The patch plan does not match the ID and current SQL definition");
        }
        return plan;
    }

    public void cleanup(RunKey run, long days) {
        mapper.lockCleanup();
        long count = mapper.cleanWork(days, run) + mapper.cleanInputWork(days, run) + mapper.cleanOutputWork(days, run)
                + mapper.cleanCopyWork(days, run) + mapper.cleanDynamoWork(days, run);
        mapper.recordCleanup(run, count);
        log.info("retainDays={} cleanedWorkRows={}", days, count);
    }

    public void freezeIncremental(Scope scope, String watermarkId, long overlapSeconds, boolean hasDateLimit) {
        mapper.createWatermark(watermarkId, scope.from());
        OffsetDateTime previous = mapper.lockWatermark(watermarkId);
        OffsetDateTime now = mapper.clock();
        OffsetDateTime upper = hasDateLimit && scope.to().isBefore(now) ? scope.to() : now;
        OffsetDateTime lower = previous.minusSeconds(overlapSeconds);
        if (!lower.isBefore(upper) || upper.isBefore(previous)) {
            throw new IllegalArgumentException("Incremental upper bound precedes the stored watermark");
        }
        Watermark bounds = new Watermark(watermarkId, lower, upper);
        mapper.createWatermarkRun(scope.run(), bounds);
        freeze(new Scope(scope.run(), scope.idFrom(), scope.idTo(), lower, upper, scope.status(),
                scope.targetStatus(), scope.maxRows(), scope.expectedRows()));
    }

    public void advanceWatermark(RunKey run) {
        Watermark bounds = mapper.watermarkRun(run);
        if (bounds == null) {
            throw new IllegalStateException("No fixed interval exists");
        }
        mapper.advanceWatermark(bounds);
    }

    public List<Long> operationIds(RunKey run, long after, int limit) {
        return mapper.operationIds(run, after, limit);
    }

    public List<Long> patchIds(String planId, long after, int limit) {
        return mapper.patchIds(planId, after, limit);
    }

    public List<CustomerRow> operationPage(RunKey run, long after, int limit) {
        return mapper.operationPage(run, after, limit);
    }

    public void streamWork(RunKey run, RowConsumer<CustomerRow> consumer) {
        readTransaction.executeWithoutResult(ignored -> {
            try (Cursor<CustomerRow> cursor = mapper.streamWork(run)) {
                for (CustomerRow row : cursor) {
                    consumer.accept(row);
                }
            } catch (Exception ex) {
                throw new IllegalStateException("Operation work export failed", ex);
            }
        });
    }

    public void streamPatch(String planId, RowConsumer<PatchRow> consumer) {
        readTransaction.executeWithoutResult(ignored -> {
            try (Cursor<PatchRow> cursor = mapper.streamPatch(planId)) {
                for (PatchRow row : cursor) {
                    consumer.accept(row);
                }
            } catch (Exception ex) {
                throw new IllegalStateException("Patch result export failed", ex);
            }
        });
    }

    private static String patchDefinition() {
        try (InputStream sql = OperationsRepository.class.getResourceAsStream("/mapper/OperationsMapper.xml")) {
            if (sql == null) {
                throw new IllegalStateException("Patch mapper is missing");
            }
            var digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[4096];
            for (int size; (size = sql.read(buffer)) != -1;) {
                digest.update(buffer, 0, size);
            }
            return "customer.status/v1/" + HexFormat.of().formatHex(digest.digest());
        } catch (IOException | NoSuchAlgorithmException e) {
            throw new IllegalStateException("Cannot fingerprint the patch SQL definition", e);
        }
    }

    private static void checkedCount(Scope scope, long actual) {
        if (actual > scope.maxRows()) {
            throw new IllegalStateException("Row count " + actual + " exceeds maxRows " + scope.maxRows());
        }
        if (scope.expectedRows() != null) {
            exact(scope.expectedRows(), actual, "Expected rows");
        }
        log.info("verifiedRows={} maxRows={}", actual, scope.maxRows());
    }

    private static void exact(long expected, long actual, String operation) {
        if (actual != expected) {
            throw new IllegalStateException(operation + " expected " + expected + " rows, affected " + actual);
        }
    }

    @FunctionalInterface
    public interface RowConsumer<T> {
        void accept(T row) throws Exception;
    }
}
