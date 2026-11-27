package cookbook.batch.examples.operations;

import java.time.OffsetDateTime;
import java.util.List;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.cursor.Cursor;

import static cookbook.batch.examples.operations.OperationModels.*;

@Mapper
public interface OperationsMapper {
    long freeze(@Param("scope") Scope scope, @Param("limit") long limit);
    long transform(RunKey run);
    long freezeStatus(@Param("scope") Scope scope, @Param("limit") long limit);
    long freezeBackfill(@Param("scope") Scope scope, @Param("limit") long limit,
                        @Param("recalculate") boolean recalculate);
    long updateStatus(@Param("run") RunKey run, @Param("ids") List<Long> ids);
    long updateEmail(@Param("run") RunKey run, @Param("ids") List<Long> ids);
    long countApplied(RunKey run);
    long lockArchiveCustomers(RunKey run);
    long countArchivedMemberships(RunKey run);
    long countWork(RunKey run);
    long countKind(@Param("run") RunKey run, @Param("kind") String kind);
    List<Long> operationIds(@Param("run") RunKey run, @Param("after") long after, @Param("limit") int limit);
    List<CustomerRow> operationPage(@Param("run") RunKey run, @Param("after") long after, @Param("limit") int limit);
    Cursor<CustomerRow> streamWork(@Param("run") RunKey run);

    long lockAggregation(String period);
    long clearAggregation(SummaryPeriod period);
    long writeAggregation(SummaryPeriod period);

    long countInputs(RunKey run);
    long countInputFiles(RunKey run);
    long countInputErrors(RunKey run);
    long countValidatedInputRows(RunKey run);
    long claimInput(RunKey run);
    long freezeDeletes(@Param("scope") Scope scope, @Param("limit") long limit);
    long deleteFrozen(@Param("run") RunKey run, @Param("reconciled") boolean reconciled);
    long freezeReconciliation(@Param("scope") Scope scope, @Param("limit") long limit);
    long insertReconciled(RunKey run);
    long updateReconciled(RunKey run);

    long createPatch(@Param("request") PatchRequest request);
    long freezePatch(@Param("request") PatchRequest request, @Param("limit") long limit);
    long setPatchCount(@Param("planId") String planId, @Param("count") long count);
    PatchPlan lockPatch(String planId);
    long claimPatch(@Param("patchId") String patchId, @Param("planId") String planId);
    long startApply(@Param("planId") String planId, @Param("runId") String runId, @Param("mode") String mode);
    long startRestore(@Param("planId") String planId, @Param("runId") String runId, @Param("mode") String mode);
    List<Long> patchIds(@Param("planId") String planId, @Param("after") long after, @Param("limit") int limit);
    long applyPatch(@Param("planId") String planId, @Param("ids") List<Long> ids);
    long restorePatch(@Param("planId") String planId, @Param("ids") List<Long> ids);
    long patchResultCount(@Param("planId") String planId, @Param("restore") boolean restore);
    long finishPatch(@Param("planId") String planId, @Param("state") String state, @Param("previous") String previous);
    Cursor<PatchRow> streamPatch(@Param("planId") String planId);

    long lockCleanup();
    long cleanWork(@Param("days") long days, @Param("run") RunKey run);
    long cleanOutputWork(@Param("days") long days, @Param("run") RunKey run);
    long cleanInputWork(@Param("days") long days, @Param("run") RunKey run);
    long cleanCopyWork(@Param("days") long days, @Param("run") RunKey run);
    long cleanDynamoWork(@Param("days") long days, @Param("run") RunKey run);
    long recordCleanup(@Param("run") RunKey run, @Param("count") long count);

    OffsetDateTime clock();
    long createWatermark(@Param("id") String id, @Param("first") OffsetDateTime first);
    OffsetDateTime lockWatermark(String id);
    long createWatermarkRun(@Param("run") RunKey run, @Param("bounds") Watermark bounds);
    Watermark watermarkRun(RunKey run);
    long advanceWatermark(Watermark bounds);
}
