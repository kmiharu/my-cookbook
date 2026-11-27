package cookbook.batch.examples;

import java.sql.Connection;
import javax.sql.DataSource;
import org.postgresql.PGConnection;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

@Component
final class DatabaseBenchmarks {
    private static final Logger log = LoggerFactory.getLogger(DatabaseBenchmarks.class);
    private final DataSource source;
    private final JdbcTemplate jdbc;
    private final RunContext run;

    DatabaseBenchmarks(DataSource source, JdbcTemplate jdbc, RunContext run) {
        this.source = source;
        this.jdbc = jdbc;
        this.run = run;
    }

    void explain() {
        if (run.job().equals("SqlOptimization")) {
            logPlan("before-non-sargable", """
                    SELECT id,name FROM customer WHERE date(updated_at AT TIME ZONE 'UTC')=DATE '2026-01-01' ORDER BY id
                    """);
            logPlan("after-range", """
                    SELECT id,name FROM customer WHERE updated_at>=TIMESTAMPTZ '2026-01-01 00:00:00+00'
                    AND updated_at<TIMESTAMPTZ '2026-01-02 00:00:00+00' ORDER BY id
                    """);
        } else {
            var retained = run.number("rows", 100000, 1, 1000000);
            jdbc.update("INSERT INTO benchmark_index_before SELECT ?,id,status,updated_at FROM customer ORDER BY id LIMIT ?",
                    run.runId(), retained);
            jdbc.update("INSERT INTO benchmark_index_after SELECT * FROM benchmark_index_before WHERE run_id=?", run.runId());
            jdbc.execute("ANALYZE benchmark_index_before");
            jdbc.execute("ANALYZE benchmark_index_after");
            logPlan("before-index", """
                    SELECT id FROM benchmark_index_before WHERE run_id=? AND status='INACTIVE'
                    AND updated_at>=TIMESTAMPTZ '2026-01-01 01:00:00+00'
                    AND updated_at<TIMESTAMPTZ '2026-01-01 02:00:00+00' ORDER BY id
                    """, run.runId());
            logPlan("after-composite-index", """
                    SELECT id FROM benchmark_index_after WHERE run_id=? AND status='INACTIVE'
                    AND updated_at>=TIMESTAMPTZ '2026-01-01 01:00:00+00'
                    AND updated_at<TIMESTAMPTZ '2026-01-01 02:00:00+00' ORDER BY id
                    """, run.runId());
            jdbc.update("DELETE FROM benchmark_index_after WHERE run_id=?", run.runId());
            jdbc.update("DELETE FROM benchmark_index_before WHERE run_id=?", run.runId());
        }
    }

    private void logPlan(String label, String reviewedQuery, Object... arguments) {
        String json = jdbc.queryForObject("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + reviewedQuery, String.class, arguments);
        log.info("explain={} {}", label, json);
    }

    void insert() throws Exception {
        String mode = run.value("mode", "batch");
        var url = source.unwrap(com.zaxxer.hikari.HikariDataSource.class).getJdbcUrl();
        var user = source.unwrap(com.zaxxer.hikari.HikariDataSource.class).getUsername();
        var password = source.unwrap(com.zaxxer.hikari.HikariDataSource.class).getPassword();
        if (url.contains("reWriteBatchedInserts")) {
            throw new IllegalArgumentException("Use mode to select reWriteBatchedInserts for this benchmark");
        }
        var properties = new java.util.Properties();
        properties.setProperty("user", user);
        if (password != null) {
            properties.setProperty("password", password);
        }
        properties.setProperty("reWriteBatchedInserts", Boolean.toString(mode.equals("rewrite")));
        try (Connection connection = java.sql.DriverManager.getConnection(url, properties)) {
            deleteRun(connection);
            connection.setAutoCommit(false);
            long rows = run.number("rows", 100, 0, 10_000_000);
            String pad = "x".repeat(run.integer("rowWidth", 256, 64, 4096) - 24);
            long start = System.nanoTime();
            try (var insert = connection.prepareStatement("INSERT INTO benchmark_insert VALUES (?,?,?)")) {
                for (long row = 1; row <= rows; row++) {
                    run.checkStop();
                    insert.setString(1, run.runId());
                    insert.setLong(2, row);
                    insert.setString(3, row + "-" + pad);
                    if (mode.equals("sequential")) {
                        insert.executeUpdate();
                    } else {
                        insert.addBatch();
                    }
                    if (row % run.chunkSize() == 0 || row == rows) {
                        if (!mode.equals("sequential")) {
                            insert.executeBatch();
                        }
                        connection.commit();
                    }
                }
            }
            long elapsed = System.nanoTime() - start;
            try (var statement = connection.prepareStatement("SELECT COUNT(*) FROM benchmark_insert WHERE run_id=?")) {
                statement.setString(1, run.runId());
                try (var counts = statement.executeQuery()) {
                    if (!counts.next() || counts.getLong(1) != rows) {
                        throw new IllegalStateException("Inserted rows do not match");
                    }
                }
            }
            deleteRun(connection);
            connection.commit();
            log.info("insert-mode={} rows={} elapsedNs={} backendPid={}", mode, rows, elapsed,
                    connection.unwrap(PGConnection.class).getBackendPID());
        }
    }
    private void deleteRun(Connection connection) throws java.sql.SQLException {
        try (var delete = connection.prepareStatement("DELETE FROM benchmark_insert WHERE run_id=?")) {
            delete.setString(1, run.runId());
            delete.executeUpdate();
        }
    }
}
