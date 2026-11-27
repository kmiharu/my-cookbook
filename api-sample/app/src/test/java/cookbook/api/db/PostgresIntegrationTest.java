package cookbook.api.db;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import cookbook.api.Product;
import cookbook.api.Repository.Page;
import cookbook.api.Settings;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

@Testcontainers
class PostgresIntegrationTest {
    private static final Instant NOW = Instant.parse("2025-06-01T00:00:00Z");
    private static final String FIRST = "00000000-0000-4000-8000-000000000001";
    private static final String SECOND = "00000000-0000-4000-8000-000000000002";
    private static final String PROJECTED = "00000000-0000-4000-8000-000000000003";

    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>(
            // postgres:16.14-bookworm. Testcontainers parses a digest and a tag as alternatives.
            DockerImageName.parse("postgres@sha256:64154d0babcb1741988719e703419af0382b19953706149f9872fbd0f438efa8"));

    @Test
    void writesUseDatabaseConditionsAndListingUsesAnExclusiveKeyset() throws Exception {
        try (PostgresRepository repository = open("aurora")) {
            Product first = product(FIRST, "books", 1, false);
            Product second = product(SECOND, "books", 1, false);
            assertTrue(repository.create(first));
            assertTrue(repository.create(second));
            assertFalse(repository.create(first));

            Page firstPage = repository.list("books", 1, null);
            assertEquals(List.of(second), firstPage.items());
            assertNotNull(firstPage.cursor());
            Page secondPage = repository.list("books", 1, firstPage.cursor());
            assertEquals(List.of(first), secondPage.items());
            assertNull(secondPage.cursor());

            try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
                CountDownLatch start = new CountDownLatch(1);
                var write1 = executor.submit(() -> {
                    start.await();
                    return repository.replace(product(FIRST, "books", 2, false), 1);
                });
                var write2 = executor.submit(() -> {
                    start.await();
                    return repository.replace(product(FIRST, "books", 2, false), 1);
                });
                start.countDown();
                assertTrue(write1.get(10, TimeUnit.SECONDS) ^ write2.get(10, TimeUnit.SECONDS));
            }
            assertEquals(2, repository.get(FIRST).orElseThrow().version());

            assertFalse(repository.replaceAtomically(List.of(
                    new PostgresRepository.Change(product(SECOND, "books", 2, false), 1),
                    new PostgresRepository.Change(product(FIRST, "books", 2, false), 1))));
            assertEquals(second, repository.get(SECOND).orElseThrow());
            assertTrue(repository.replaceAtomically(List.of(
                    new PostgresRepository.Change(product(SECOND, "books", 2, false), 1),
                    new PostgresRepository.Change(product(FIRST, "books", 3, false), 2))));
        }
    }

    @Test
    void projectionIsIdempotentAndRetainsTheDeletionHighWaterMark() {
        try (PostgresRepository repository = open("hybrid")) {
            Product version1 = product(PROJECTED, "tools", 1, false);
            Product version2 = product(PROJECTED, "tools", 2, false);
            Product removeVersion2 = product(PROJECTED, "tools", 2, true);

            assertTrue(repository.project(version2));
            assertFalse(repository.project(version2));
            assertFalse(repository.project(version1));
            assertTrue(repository.project(removeVersion2));
            assertFalse(repository.project(version2));
            assertFalse(repository.project(product(PROJECTED, "tools", 3, false)));
            assertTrue(repository.list("tools", 5, null).items().isEmpty());
            assertEquals(removeVersion2, repository.get(PROJECTED).orElseThrow());

            assertThrows(IllegalStateException.class, () -> repository.rebuild(sink -> {
                sink.accept(version1);
                throw new IllegalStateException("Interrupted snapshot");
            }));
            assertEquals(removeVersion2, repository.get(PROJECTED).orElseThrow());
            repository.rebuild(sink -> {
                sink.accept(removeVersion2);
                sink.accept(version2);
            });
            assertEquals(removeVersion2, repository.get(PROJECTED).orElseThrow());
        }
    }

    private static PostgresRepository open(String mode) {
        Settings settings = Settings.from(Map.of(
                "APP_RUNTIME", "local",
                "DATABASE_TYPE", mode,
                "DYNAMODB_ENDPOINT", "http://localhost:8000",
                "DYNAMODB_TABLE", "products",
                "PG_JDBC_URL", "jdbc:postgresql://localhost:" + POSTGRES.getMappedPort(5432) + "/" + POSTGRES.getDatabaseName(),
                "PG_USER", POSTGRES.getUsername(),
                "PG_PASSWORD", POSTGRES.getPassword()));
        PostgresAdmin.migrate(settings);
        return new PostgresRepository(settings);
    }

    private static Product product(String id, String category, long version, boolean deleted) {
        return new Product(id, "Sample", category, 100, "ACTIVE", version, NOW, NOW, deleted);
    }
}
