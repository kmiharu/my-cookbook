package cookbook.api.db;

import cookbook.api.Product;
import cookbook.api.Repository;
import cookbook.api.Settings;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.UUID;
import org.flywaydb.core.Flyway;

public final class PostgresAdmin {
    private static final String USAGE = """
            PostgresAdmin migrate
            PostgresAdmin search <category> <ACTIVE|INACTIVE> <minimum-price> <limit>
            PostgresAdmin paging <limit> <offset>
            PostgresAdmin atomic <id> <version> <price> <id> <version> <price>
            """;

    private PostgresAdmin() {}

    public static void main(String[] args) {
        if (args.length == 0) {
            throw new IllegalArgumentException(USAGE);
        }
        Settings settings = Settings.fromEnvironment();
        if ("migrate".equals(args[0]) && args.length == 1) {
            migrate(settings);
            return;
        }
        if (!settings.local() || !"aurora".equals(settings.mode())) {
            throw new IllegalArgumentException("PostgreSQL examples require local aurora mode");
        }
        try (PostgresRepository repository = new PostgresRepository(settings)) {
            switch (args[0]) {
                case "search" -> search(repository, args);
                case "paging" -> paging(repository, args);
                case "atomic" -> atomic(repository, args);
                default -> throw new IllegalArgumentException(USAGE);
            }
        }
    }

    static void migrate(Settings settings) {
        String jdbcUrl = settings.jdbcUrl();
        PostgresCredentials credentials = PostgresCredentials.load(settings);
        Flyway.configure()
                .dataSource(jdbcUrl, credentials.username(), credentials.password())
                .cleanDisabled(true)
                .load()
                .migrate();
    }

    private static void search(PostgresRepository repository, String[] args) {
        if (args.length != 5 || !List.of("ACTIVE", "INACTIVE").contains(args[2])) {
            throw new IllegalArgumentException(USAGE);
        }
        repository.searchWithCategory(args[1], args[2], price(args[3]), limit(args[4]))
                .forEach(System.out::println);
    }

    private static void paging(PostgresRepository repository, String[] args) {
        if (args.length != 3) {
            throw new IllegalArgumentException(USAGE);
        }
        int limit = limit(args[1]);
        int offset = Integer.parseInt(args[2]);
        if (offset < 0) {
            throw new IllegalArgumentException("offset must be nonnegative");
        }
        List<Product> offsetPage = repository.listOffset(limit, offset);
        String cursor = null;
        if (offset > 0) {
            List<Product> previous = repository.listOffset(1, offset - 1);
            if (previous.isEmpty()) {
                System.out.println("Both pages are empty");
                return;
            }
            Product last = previous.getFirst();
            cursor = last.createdAt() + "|" + last.id();
        }
        Repository.Page keysetPage = repository.list(null, limit, cursor);
        System.out.println("OFFSET  " + offsetPage.stream().map(Product::id).toList());
        System.out.println("KEYSET  " + keysetPage.items().stream().map(Product::id).toList());
    }

    private static void atomic(PostgresRepository repository, String[] args) {
        if (args.length != 7) {
            throw new IllegalArgumentException(USAGE);
        }
        String first = UUID.fromString(args[1]).toString();
        String second = UUID.fromString(args[4]).toString();
        if (first.equals(second)) {
            throw new IllegalArgumentException("atomic example requires two distinct IDs");
        }
        List<PostgresRepository.Change> changes = List.of(
                change(repository, first, Long.parseLong(args[2]), price(args[3])),
                change(repository, second, Long.parseLong(args[5]), price(args[6])));
        if (!repository.replaceAtomically(changes)) {
            throw new IllegalStateException("Version conflict or deleted product. Transaction rolled back.");
        }
        System.out.println("Updated two products in one transaction");
    }

    private static PostgresRepository.Change change(PostgresRepository repository, String id,
            long expectedVersion, long price) {
        if (expectedVersion < 1 || expectedVersion == Long.MAX_VALUE) {
            throw new IllegalArgumentException("Invalid version");
        }
        Product current = repository.get(id).orElseThrow(() -> new IllegalArgumentException("Unknown product " + id));
        Product next = new Product(id, current.name(), current.category(), price, current.status(),
                expectedVersion + 1, current.createdAt(), Instant.now().truncatedTo(ChronoUnit.MILLIS), false);
        return new PostgresRepository.Change(next, expectedVersion);
    }

    private static long price(String input) {
        long value = Long.parseLong(input);
        if (value < 0 || value > 999_999_999) {
            throw new IllegalArgumentException("Invalid price");
        }
        return value;
    }

    private static int limit(String input) {
        int value = Integer.parseInt(input);
        if (value < 1 || value > 100) {
            throw new IllegalArgumentException("Invalid limit");
        }
        return value;
    }
}
