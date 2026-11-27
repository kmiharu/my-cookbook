package cookbook.batch.examples.operations;

import java.util.List;
import java.util.Properties;
import java.util.function.BooleanSupplier;

import org.flywaydb.core.Flyway;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import static cookbook.batch.examples.operations.OperationModels.CustomerRow;

public final class MigrationTarget {
    private final DriverManagerDataSource dataSource;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transaction;

    MigrationTarget(Environment environment) {
        String url = environment.getProperty("BATCH_TARGET_DB_URL");
        if (url == null || !url.startsWith("jdbc:postgresql:")) {
            throw new IllegalArgumentException("DataMigration requires BATCH_TARGET_DB_URL for a separate PostgreSQL DB");
        }
        dataSource = new DriverManagerDataSource(url, environment.getProperty("BATCH_TARGET_DB_USER"),
                environment.getProperty("BATCH_TARGET_DB_PASSWORD"));
        var connectionOptions = new Properties();
        connectionOptions.setProperty("connectTimeout", "8");
        connectionOptions.setProperty("socketTimeout", "35");
        dataSource.setConnectionProperties(connectionOptions);
        jdbc = new JdbcTemplate(dataSource);
        jdbc.setQueryTimeout(30);
        transaction = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        transaction.setTimeout(45);
    }

    void verifySeparate(Environment environment) {
        String primary = environment.getProperty("BATCH_DB_URL",
                environment.getProperty("spring.datasource.url", ""));
        if (primary.equals(dataSource.getUrl())) {
            throw new IllegalArgumentException("DataMigration requires a separate target PostgreSQL database");
        }
    }

    public static void prepare(Environment environment) {
        if (environment.getProperty("BATCH_TARGET_DB_URL", "").isEmpty()) {
            return;
        }
        var target = new MigrationTarget(environment);
        target.verifySeparate(environment);
        target.migrate();
    }

    void validateSchema() {
        jdbc.queryForList("SELECT id, name, email, status, updated_at, version FROM customer LIMIT 0");
        jdbc.queryForList("SELECT run_id, customer_id FROM batch_migration_progress LIMIT 0");
    }

    private void migrate() {
        Flyway.configure()
                .dataSource(dataSource)
                .locations("classpath:db/migration-target")
                .table("batch_migration_flyway_history")
                .load().migrate();
    }

    void copy(String runId, List<? extends CustomerRow> rows, BooleanSupplier stopping) {
        transaction.executeWithoutResult(ignored -> {
            for (CustomerRow row : rows) {
                if (stopping.getAsBoolean() || Thread.currentThread().isInterrupted()) {
                    throw new IllegalStateException("Stop requested during target transaction");
                }
                if (jdbc.update("""
                        INSERT INTO batch_migration_progress(run_id, customer_id) VALUES (?, ?)
                        ON CONFLICT DO NOTHING
                        """, runId, row.id()) == 0) {
                    continue;
                }
                if (jdbc.update("""
                        INSERT INTO customer(id, name, email, status, updated_at, version)
                        VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                        """, row.id(), row.name(), row.email(), row.status(), row.updatedAt(), row.version()) == 0) {
                    Integer matching = jdbc.queryForObject("""
                            SELECT count(*) FROM customer WHERE id = ? AND name = ?
                              AND email IS NOT DISTINCT FROM ? AND status = ? AND updated_at = ? AND version = ?
                            """, Integer.class, row.id(), row.name(), row.email(), row.status(), row.updatedAt(), row.version());
                    if (matching == null || matching != 1) {
                        throw new IllegalStateException("Migration conflict for customer " + row.id());
                    }
                }
            }
        });
    }
}
