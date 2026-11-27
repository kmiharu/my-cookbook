package cookbook.batch.examples.operations;

import java.time.OffsetDateTime;
import java.util.List;

import javax.sql.DataSource;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.mybatis.spring.SqlSessionFactoryBean;
import org.mybatis.spring.SqlSessionTemplate;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

import static cookbook.batch.examples.operations.OperationModels.RunKey;
import static cookbook.batch.examples.operations.OperationModels.Scope;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

@Testcontainers
class OperationsRepositoryIntegrationTest {
    @Container
    static final PostgreSQLContainer postgres = new PostgreSQLContainer(DockerImageName.parse(
            "postgres:16.15-bookworm@sha256:5264710be20f409750ac6dc4e5706dcef929c87e241605463f0f9aefa932a8d9")
            .asCompatibleSubstituteFor("postgres"));

    private static OperationsRepository operations;
    private static JdbcTemplate jdbc;
    private static TransactionTemplate transaction;

    @BeforeAll
    static void database() throws Exception {
        DataSource source = new DriverManagerDataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword());
        new ResourceDatabasePopulator(
                new ClassPathResource("db/migration/V2__customer_work_and_ledger.sql"),
                new ClassPathResource("db/migration/V3__operation_work.sql"),
                new ClassPathResource("db/migration/V4__dynamodb_examples.sql")).execute(source);
        var factory = new SqlSessionFactoryBean();
        factory.setDataSource(source);
        factory.setMapperLocations(new ClassPathResource("mapper/OperationsMapper.xml"));
        factory.afterPropertiesSet();
        var mapper = new SqlSessionTemplate(factory.getObject()).getMapper(OperationsMapper.class);
        var manager = new DataSourceTransactionManager(source);
        operations = new OperationsRepository(mapper, manager);
        jdbc = new JdbcTemplate(source);
        transaction = new TransactionTemplate(manager);
    }

    @Test
    void rollsBackSinglePatchAndAuditOnVersionConflict() {
        customer(100, "INACTIVE");
        customer(101, "INACTIVE");
        RunKey preview = new RunKey("DataPatchPreview", "single-conflict-preview");
        tx(() -> operations.previewPatch(scope(preview, 100, 101, 2), "single-conflict", "single-plan"));
        assertEquals("INACTIVE", status(100));
        jdbc.update("UPDATE customer SET version=version+1 WHERE id=101");
        RunKey apply = new RunKey("DataPatchApply", "single-conflict-apply");
        assertThrows(IllegalStateException.class, () -> tx(() -> {
            operations.startPatch(scope(apply, 100, 101, 2), "single-conflict", "single-plan", "single", false);
            operations.patchAll(apply, "single-conflict", "single-plan", false);
            operations.finishPatch(apply, "single-conflict", "single-plan", false);
        }));
        assertEquals("INACTIVE", status(100));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM batch_patch_claim WHERE patch_id='single-conflict'", Long.class));
        assertEquals("PREVIEWED", state("single-plan"));
    }

    @Test
    void committedPatchChunkSurvivesLaterConflict() {
        customer(200, "INACTIVE");
        customer(201, "INACTIVE");
        RunKey preview = new RunKey("DataPatchPreview", "chunk-conflict-preview");
        tx(() -> operations.previewPatch(scope(preview, 200, 201, 2), "chunk-conflict", "chunk-plan"));
        RunKey apply = new RunKey("DataPatchApply", "chunk-conflict-apply");
        tx(() -> operations.startPatch(scope(apply, 200, 201, 2), "chunk-conflict", "chunk-plan", "chunk", false));
        tx(() -> operations.patchChunk(apply, "chunk-conflict", "chunk-plan", List.of(200L), false));
        jdbc.update("UPDATE customer SET version=version+1 WHERE id=201");
        assertThrows(IllegalStateException.class, () -> tx(() ->
                operations.patchChunk(apply, "chunk-conflict", "chunk-plan", List.of(201L), false)));
        assertEquals("ACTIVE", status(200));
        assertEquals("INACTIVE", status(201));
        assertEquals("APPLYING", state("chunk-plan"));
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM batch_patch_row WHERE plan_id='chunk-plan' AND applied_version IS NOT NULL", Long.class));
    }

    @Test
    void restoresOnlyChangedColumnAndRejectsSecondApply() {
        customer(300, "INACTIVE");
        RunKey preview = new RunKey("DataPatchPreview", "restore-preview");
        tx(() -> operations.previewPatch(scope(preview, 300, 300, 1), "restore", "restore-plan"));
        RunKey apply = new RunKey("DataPatchApply", "restore-apply");
        tx(() -> {
            operations.startPatch(scope(apply, 300, 300, 1), "restore", "restore-plan", "single", false);
            operations.patchAll(apply, "restore", "restore-plan", false);
            operations.finishPatch(apply, "restore", "restore-plan", false);
        });
        assertEquals("ACTIVE", status(300));
        assertThrows(IllegalStateException.class, () -> tx(() ->
                operations.startPatch(scope(apply, 300, 300, 1), "restore", "restore-plan", "single", false)));
        RunKey restore = new RunKey("DataPatchRestore", "restore");
        tx(() -> {
            operations.startPatch(scope(restore, 300, 300, 1), "restore", "restore-plan", "single", true);
            operations.patchAll(restore, "restore", "restore-plan", true);
            operations.finishPatch(restore, "restore", "restore-plan", true);
        });
        assertEquals("INACTIVE", status(300));
        assertEquals("RESTORED", state("restore-plan"));
        assertEquals(2L, jdbc.queryForObject("SELECT version FROM customer WHERE id=300", Long.class));
        assertEquals("customer-300", jdbc.queryForObject("SELECT name FROM customer WHERE id=300", String.class));
    }

    @Test
    void rejectsRestoreAfterLaterBusinessChange() {
        customer(301, "INACTIVE");
        RunKey preview = new RunKey("DataPatchPreview", "changed-preview");
        tx(() -> operations.previewPatch(scope(preview, 301, 301, 1), "changed", "changed-plan"));
        RunKey apply = new RunKey("DataPatchApply", "changed-apply");
        tx(() -> {
            operations.startPatch(scope(apply, 301, 301, 1), "changed", "changed-plan", "single", false);
            operations.patchAll(apply, "changed", "changed-plan", false);
            operations.finishPatch(apply, "changed", "changed-plan", false);
        });
        jdbc.update("UPDATE customer SET name='later business value', version=version+1 WHERE id=301");
        RunKey restore = new RunKey("DataPatchRestore", "changed-restore");
        assertThrows(IllegalStateException.class, () -> tx(() -> {
            operations.startPatch(scope(restore, 301, 301, 1), "changed", "changed-plan", "single", true);
            operations.patchAll(restore, "changed", "changed-plan", true);
        }));
        assertEquals("ACTIVE", status(301));
        assertEquals("APPLIED", state("changed-plan"));
        assertEquals("later business value", jdbc.queryForObject("SELECT name FROM customer WHERE id=301", String.class));
    }

    @Test
    void cleanupRetainsFailedAndActiveRunWork() {
        for (String state : List.of("ACTIVE", "FAILED", "STOPPED", "COMPLETED")) {
            jdbc.update("""
                    INSERT INTO batch_run(job_name,run_id,state,settings,owner,owner_location,updated_at)
                    VALUES ('StatusUpdate',?,?, '{}', 'test-owner','junit',clock_timestamp()-interval '90 days')
                    """, state, state);
            jdbc.update("""
                    INSERT INTO batch_operation_work(job_name,run_id,id,name,status,updated_at,version)
                    VALUES ('StatusUpdate',?,999,'test','ACTIVE',clock_timestamp(),0)
                    """, state);
            jdbc.update("INSERT INTO dynamo_run(run_key) VALUES (?)", "StatusUpdate:" + state);
            jdbc.update("""
                    INSERT INTO dynamo_work(run_key,pk,sk,version,memo_state)
                    VALUES (?,'tenant','key',0,'MISSING')
                    """, "StatusUpdate:" + state);
        }
        tx(() -> operations.cleanup(new RunKey("DataCleanup", "retention-check"), 30));
        assertEquals(List.of("ACTIVE", "FAILED", "STOPPED"), jdbc.queryForList(
                "SELECT run_id FROM batch_operation_work WHERE job_name='StatusUpdate' AND id=999 ORDER BY run_id", String.class));
        assertEquals(List.of("StatusUpdate:ACTIVE", "StatusUpdate:FAILED", "StatusUpdate:STOPPED"),
                jdbc.queryForList("SELECT run_key FROM dynamo_work ORDER BY run_key", String.class));
        assertEquals(4L, jdbc.queryForObject("SELECT count(*) FROM dynamo_run", Long.class));
    }

    @Test
    void keepsArchiveDispositionAndVersionConditionWithTheDelete() {
        customer(400, "INACTIVE");
        customer(401, "INACTIVE");
        RunKey run = new RunKey("DataArchive", "archive-case");
        tx(() -> operations.freezeArchive(scope(run, 400, 401, 2)));
        jdbc.update("UPDATE customer SET version=version+1 WHERE id=401");
        assertThrows(IllegalStateException.class, () -> tx(() -> operations.deleteArchived(run)));
        assertEquals("INACTIVE", status(400));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM batch_operation_work WHERE run_id='archive-case' AND applied", Long.class));

        RunKey current = new RunKey("DataArchive", "archive-current");
        tx(() -> operations.freezeArchive(scope(current, 400, 401, 2)));
        tx(() -> operations.deleteArchived(current));
        tx(() -> operations.deleteArchived(current));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM customer WHERE id BETWEEN 400 AND 401", Long.class));
        assertEquals(2L, jdbc.queryForObject("SELECT count(*) FROM batch_operation_work WHERE run_id='archive-current' AND applied", Long.class));
    }

    @Test
    void protectsMembershipAddedBetweenArchiveFreezeAndDelete() {
        customer(402, "ACTIVE");
        RunKey run = new RunKey("DataArchive", "archive-with-new-dependency");
        tx(() -> operations.freezeArchive(scope(run, 402, 402, 1)));
        jdbc.update("INSERT INTO membership(customer_id,member_id,tier) VALUES (402,1,'BASIC')");
        assertThrows(IllegalStateException.class, () -> tx(() -> operations.deleteArchived(run)));
        assertEquals("ACTIVE", status(402));
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM membership WHERE customer_id=402", Long.class));
    }

    @Test
    void fixesIncrementalBoundsAndAdvancesOnlyAfterPublicationStep() {
        RunKey first = new RunKey("IncrementalExport", "watermark-one");
        customer(550, "INACTIVE");
        tx(() -> operations.freezeIncremental(scope(first, 550, 550, 1), "test-customers", 900, false));
        var bounds = jdbc.queryForMap("SELECT lower_bound, upper_bound FROM batch_watermark_run WHERE run_id='watermark-one'");
        assertEquals(java.sql.Timestamp.from(java.time.Instant.parse("2019-12-31T23:45:00Z")), bounds.get("lower_bound"));
        var previous = jdbc.queryForObject("SELECT next_lower FROM batch_watermark WHERE watermark_id='test-customers'", java.sql.Timestamp.class);
        assertEquals(java.time.Instant.parse("2020-01-01T00:00:00Z"), previous.toInstant());
        tx(() -> operations.advanceWatermark(first));
        assertEquals(bounds.get("upper_bound"),
                jdbc.queryForObject("SELECT next_lower FROM batch_watermark WHERE watermark_id='test-customers'", java.sql.Timestamp.class));
        jdbc.update("UPDATE customer SET status='ACTIVE', version=1 WHERE id=550");
        assertEquals("INACTIVE", operations.operationPage(first, 0, 10).getFirst().status());
    }

    @Test
    void reaggregatesUtcDaysWithoutAddingCountsAgain() {
        jdbc.update("INSERT INTO customer(id,name,status,updated_at) VALUES (600,'sum','ACTIVE','2099-03-01T00:00:00Z')");
        jdbc.update("INSERT INTO customer(id,name,status,updated_at) VALUES (601,'sum-two','ACTIVE','2099-03-02T00:00:00Z')");
        var period = new OperationModels.SummaryPeriod("day", java.time.LocalDate.of(2099, 3, 1),
                java.time.LocalDate.of(2099, 3, 2));
        tx(() -> operations.aggregate(period));
        tx(() -> operations.aggregate(period));
        assertEquals(1L, jdbc.queryForObject("""
                SELECT customer_count FROM batch_customer_totals WHERE period='day' AND bucket_date='2099-03-01'
                """, Long.class));
    }

    private static Scope scope(RunKey run, long first, long last, long count) {
        return new Scope(run, first, last, OffsetDateTime.parse("2020-01-01T00:00:00Z"),
                OffsetDateTime.parse("2100-01-01T00:00:00Z"), null, "ACTIVE", count, count);
    }

    private static void customer(long id, String status) {
        jdbc.update("INSERT INTO customer(id,name,status) VALUES (?,?,?)", id, "customer-" + id, status);
    }

    private static String status(long id) {
        return jdbc.queryForObject("SELECT status FROM customer WHERE id=?", String.class, id);
    }

    private static String state(String plan) {
        return jdbc.queryForObject("SELECT state FROM batch_patch_plan WHERE plan_id=?", String.class, plan);
    }

    private static void tx(Runnable action) {
        transaction.executeWithoutResult(ignored -> action.run());
    }
}
