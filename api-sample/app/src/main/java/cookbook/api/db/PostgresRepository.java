package cookbook.api.db;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import cookbook.api.Product;
import cookbook.api.Repository;
import cookbook.api.Settings;
import java.io.InputStream;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Consumer;
import org.apache.ibatis.builder.xml.XMLMapperBuilder;
import org.apache.ibatis.mapping.Environment;
import org.apache.ibatis.session.Configuration;
import org.apache.ibatis.session.SqlSession;
import org.apache.ibatis.session.SqlSessionFactory;
import org.apache.ibatis.session.SqlSessionFactoryBuilder;
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory;

public final class PostgresRepository implements Repository, AutoCloseable {
    private static final String MAPPER = "/cookbook/api/db/PostgresStatements.xml";
    private final HikariDataSource pool;
    private final SqlSessionFactory sessions;

    public PostgresRepository(Settings settings) {
        String jdbcUrl = settings.jdbcUrl();
        PostgresCredentials credentials = PostgresCredentials.load(settings);
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(credentials.username());
        config.setPassword(credentials.password());
        config.setMaximumPoolSize(settings.pgPoolSize());
        config.setMinimumIdle(0);
        config.setConnectionTimeout(5_000);
        config.setValidationTimeout(1_000);
        config.setInitializationFailTimeout(-1);
        config.addDataSourceProperty("connectTimeout", "3");
        config.addDataSourceProperty("socketTimeout", "5");

        pool = new HikariDataSource(config);
        try {
            sessions = createSessions(pool);
        } catch (RuntimeException e) {
            pool.close();
            throw e;
        }
    }

    private static SqlSessionFactory createSessions(HikariDataSource pool) {
        Environment environment = new Environment("postgres", new JdbcTransactionFactory(), pool);
        Configuration config = new Configuration(environment);
        try (InputStream in = PostgresRepository.class.getResourceAsStream(MAPPER)) {
            if (in == null) {
                throw new IllegalStateException("Missing MyBatis mapper " + MAPPER);
            }
            new XMLMapperBuilder(in, config, MAPPER, config.getSqlFragments()).parse();
            return new SqlSessionFactoryBuilder().build(config);
        } catch (java.io.IOException e) {
            throw new IllegalStateException("Cannot read MyBatis mapper", e);
        }
    }

    @Override
    public boolean create(Product product) {
        try (SqlSession session = sessions.openSession()) {
            boolean written = session.insert("products.create", values(product)) == 1;
            session.commit();
            return written;
        }
    }

    @Override
    public Optional<Product> get(String id) {
        try (SqlSession session = sessions.openSession()) {
            Map<String, Object> row = session.selectOne("products.get", Map.of("id", id));
            return Optional.ofNullable(row).map(PostgresRepository::product);
        }
    }

    @Override
    public boolean replace(Product product, long expectedVersion) {
        try (SqlSession session = sessions.openSession()) {
            boolean written = replace(session, product, expectedVersion);
            session.commit();
            return written;
        }
    }

    private static boolean replace(SqlSession session, Product product, long expectedVersion) {
        Map<String, Object> parameters = values(product);
        parameters.put("expectedVersion", expectedVersion);
        return session.update("products.replace", parameters) == 1;
    }

    @Override
    public Page list(String category, int limit, String cursor) {
        Map<String, Object> parameters = new HashMap<>();
        parameters.put("category", category);
        parameters.put("limit", limit + 1);
        if (cursor != null) {
            String[] parts = cursor.split("\\|", 2);
            if (parts.length != 2) {
                throw new IllegalArgumentException("Invalid PostgreSQL cursor");
            }
            try {
                Instant after = Instant.parse(parts[0]);
                String id = UUID.fromString(parts[1]).toString();
                if (!id.equals(parts[1]) || !after.toString().equals(parts[0])) {
                    throw new IllegalArgumentException("Invalid PostgreSQL cursor");
                }
                parameters.put("afterTime", after);
                parameters.put("afterId", id);
            } catch (DateTimeParseException e) {
                throw new IllegalArgumentException("Invalid PostgreSQL cursor", e);
            }
        }
        try (SqlSession session = sessions.openSession()) {
            List<Map<String, Object>> rows = session.selectList("products.list", parameters);
            List<Product> products = rows.stream().limit(limit).map(PostgresRepository::product).toList();
            String next = null;
            if (rows.size() > limit) {
                Product last = products.getLast();
                next = last.createdAt() + "|" + last.id();
            }
            return new Page(products, next);
        }
    }

    public boolean project(Product product) {
        try (SqlSession session = sessions.openSession()) {
            boolean applied = session.insert("products.project", values(product)) == 1;
            session.commit();
            return applied;
        }
    }

    public void rebuild(Consumer<Consumer<Product>> snapshot) {
        try (SqlSession session = sessions.openSession()) {
            try (Statement sql = session.getConnection().createStatement()) {
                sql.execute("CREATE TEMP TABLE products_rebuild (LIKE products INCLUDING ALL) ON COMMIT DROP");
                snapshot.accept(product -> session.insert("products.stage", values(product)));
                sql.execute("TRUNCATE TABLE products");
                sql.execute("INSERT INTO products SELECT * FROM products_rebuild");
                session.commit(true);
            } catch (SQLException e) {
                session.rollback(true);
                throw new IllegalStateException("Cannot replace PostgreSQL projection", e);
            } catch (RuntimeException e) {
                session.rollback(true);
                throw e;
            }
        }
    }

    public record Change(Product product, long expectedVersion) {}

    public boolean replaceAtomically(List<Change> changes) {
        try (SqlSession session = sessions.openSession()) {
            for (Change change : changes) {
                if (!replace(session, change.product(), change.expectedVersion())) {
                    session.rollback();
                    return false;
                }
            }
            session.commit();
            return true;
        }
    }

    public List<Map<String, Object>> searchWithCategory(String category, String status, long minPrice, int limit) {
        try (SqlSession session = sessions.openSession()) {
            return session.selectList("products.searchWithCategory",
                    Map.of("category", category, "status", status, "minPrice", minPrice, "limit", limit));
        }
    }

    public List<Product> listOffset(int limit, int offset) {
        try (SqlSession session = sessions.openSession()) {
            List<Map<String, Object>> rows = session.selectList("products.offset",
                    Map.of("limit", limit, "offset", offset));
            return rows.stream().map(PostgresRepository::product).toList();
        }
    }

    private static Map<String, Object> values(Product product) {
        Map<String, Object> values = new HashMap<>();
        values.put("id", product.id());
        values.put("name", product.name());
        values.put("category", product.category());
        values.put("priceMinor", product.priceMinor());
        values.put("status", product.status());
        values.put("version", product.version());
        values.put("createdAt", product.createdAt());
        values.put("updatedAt", product.updatedAt());
        values.put("deleted", product.deleted());
        return values;
    }

    private static Product product(Map<String, Object> row) {
        return new Product(row.get("id").toString(), (String) row.get("name"),
                (String) row.get("category"), ((Number) row.get("price_minor")).longValue(),
                (String) row.get("status"), ((Number) row.get("version")).longValue(),
                ((Timestamp) row.get("created_at")).toInstant(), ((Timestamp) row.get("updated_at")).toInstant(),
                (Boolean) row.get("deleted"));
    }

    @Override
    public void close() {
        pool.close();
    }
}
