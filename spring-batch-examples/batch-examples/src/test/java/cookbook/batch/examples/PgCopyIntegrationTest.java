package cookbook.batch.examples;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import cookbook.batch.database.PgCopy;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

@Testcontainers
class PgCopyIntegrationTest {
    @Container
    static final PostgreSQLContainer db = new PostgreSQLContainer(DockerImageName.parse(
            "postgres:16.15-bookworm@sha256:5264710be20f409750ac6dc4e5706dcef929c87e241605463f0f9aefa932a8d9").asCompatibleSubstituteFor("postgres"));

    private static HikariDataSource pool;
    private static JdbcTemplate jdbc;

    @BeforeAll
    static void setup() {
        var config = new HikariConfig();
        config.setJdbcUrl(db.getJdbcUrl());
        config.setUsername(db.getUsername());
        config.setPassword(db.getPassword());
        config.setMaximumPoolSize(1);
        Flyway.configure().dataSource(db.getJdbcUrl(), db.getUsername(), db.getPassword()).load().migrate();
        pool = new HikariDataSource(config);
        jdbc = new JdbcTemplate(pool);
    }

    @AfterAll
    static void close() {
        if (pool != null) {
            pool.close();
        }
    }

    @Test
    void utf8CopyIsolatesQuotedRunSettingsAndPreservesFieldNewlines() throws Exception {
        var copy = new PgCopy(pool);
        String job = "取込'sample";
        String run = "試行 / 'one";
        try (var input = bytes("id\tname\temail\tstatus\n1\t\"名\n前\"\t\"\"\tACTIVE\n")) {
            assertEquals(1, copy.importCustomers(job, run, true, true, input, 1, () -> {}));
        }
        assertEquals("名\n前", jdbc.queryForObject(
                "SELECT name FROM batch_copy_stage WHERE job_name=? AND run_id=?", String.class, job, run));
        assertEquals("", jdbc.queryForObject(
                "SELECT email FROM batch_copy_stage WHERE job_name=? AND run_id=?", String.class, job, run));
        assertEquals("", jdbc.queryForObject("SELECT current_setting('batch.run_id',true)", String.class));
        try (var input = bytes("2,another,,ACTIVE\n")) {
            assertEquals(1, copy.importCustomers(job, "another", false, false, input, 1, () -> {}));
        }
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM batch_copy_stage WHERE run_id=?", Long.class, run));
    }

    @Test
    void checksumAndRowCountFailureRollBackTheFile() {
        var copy = new PgCopy(pool);
        assertThrows(IOException.class, () -> copy.importCustomers(
                "copy", "bad-digest", false, false, bytes("1,valid,,ACTIVE\n"), 1,
                () -> { throw new IOException("checksum mismatch"); }));
        assertThrows(IllegalStateException.class, () -> copy.importCustomers(
                "copy", "short-file", false, false, bytes("1,valid,,ACTIVE\n"), 2, () -> {}));
        assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM batch_copy_stage WHERE job_name='copy'", Long.class));
    }

    private static ByteArrayInputStream bytes(String value) {
        return new ByteArrayInputStream(value.getBytes(StandardCharsets.UTF_8));
    }
}
