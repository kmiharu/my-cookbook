package cookbook.batch.examples.dynamo;

import java.time.Instant;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.cursor.Cursor;

@Mapper
public interface DynamoMapper {
    record Work(String runKey, String pk, String sk, long version, String status, java.math.BigDecimal balance,
                String memoState, String memo, Long ordinal) { }
    record State(String nextPage, String state, Long inputRows, String inputSha256) { }
    record Counts(long expected, long updated) { }
    record PgSeed(String runKey, String partition, String status, Instant fromDate, Instant toDate) { }

    void start(String runKey);
    State state(String runKey);
    int stage(@Param("rows") List<Work> rows);
    int stagePage(@Param("rows") List<Work> rows);
    int savePage(@Param("runKey") String runKey, @Param("nextPage") String nextPage,
            @Param("last") boolean last);
    int inputEnd(@Param("runKey") String runKey, @Param("rows") long rows, @Param("sha256") String sha256);
    int seal(String runKey);
    int applied(String runKey);
    Cursor<Work> stream(String runKey);
    List<Work> pending(@Param("runKey") String runKey, @Param("limit") int limit);
    int delivered(@Param("runKey") String runKey, @Param("rows") List<Work> rows);
    int seed(PgSeed seed);
    int validatePgDelivery(String runKey);
    Counts stageOutbox(PgSeed seed);
    List<Work> nextOutbox(@Param("runKey") String runKey, @Param("limit") int limit);
    long undeliveredOutbox(String runKey);
    int outboxDelivered(@Param("runKey") String runKey, @Param("rows") List<Work> rows);
    int validatePgKeys(String runKey);
    Counts applyPg(String runKey);
    int markApplied(String runKey);
    long countWork(String runKey);
    long countOutbox(String runKey);
    String claimGeneration(@Param("pk") String partition, @Param("runKey") String runKey);
    String assertGenerationWritable(String partition);
    String generationOwner(String partition);
    int markGenerationDelivered(@Param("pk") String partition, @Param("runKey") String runKey);
    String claimInput(@Param("job") String job, @Param("revision") String revision,
            @Param("partition") String partition, @Param("runKey") String runKey);
}
