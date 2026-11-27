package cookbook.batch.examples;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.cursor.Cursor;

@Mapper
public interface CustomerMapper {
    Cursor<CustomerRow> selectCustomers(CustomerConditions conditions);

    int snapshot(@Param("job") String job, @Param("run") String run, @Param("artifact") String artifact,
                 @Param("conditions") CustomerConditions conditions);

    int snapshotImported(@Param("job") String job, @Param("run") String run);

    int promoteCopyRows(@Param("job") String job, @Param("run") String run);

    int snapshotMembers(@Param("job") String job, @Param("run") String run,
                        @Param("conditions") CustomerConditions conditions);

    Cursor<CustomerRow> selectWork(@Param("job") String job, @Param("run") String run,
                                   @Param("artifact") String artifact, @Param("low") long low,
                                   @Param("high") long high);

    Cursor<InputError> selectErrors(@Param("job") String job, @Param("run") String run);

    int stage(InputCustomer item);

    int insert(InputCustomer item);

    int error(InputCustomer item);

    long upsert(@Param("job") String job, @Param("run") String run);

    int seed(@Param("start") long start, @Param("end") long end,
             @Param("width") int width, @Param("seed") int seed);

    record InputError(int fileIndex, long ordinal, String reason) {}
}
