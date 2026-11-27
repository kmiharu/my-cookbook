package cookbook.api.db;

import static cookbook.api.db.DynamoSupport.*;

import cookbook.api.Product;
import cookbook.api.Settings;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Function;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeDefinition;
import software.amazon.awssdk.services.dynamodb.model.BillingMode;
import software.amazon.awssdk.services.dynamodb.model.DeleteRequest;
import software.amazon.awssdk.services.dynamodb.model.GlobalSecondaryIndex;
import software.amazon.awssdk.services.dynamodb.model.KeySchemaElement;
import software.amazon.awssdk.services.dynamodb.model.KeyType;
import software.amazon.awssdk.services.dynamodb.model.ProjectionType;
import software.amazon.awssdk.services.dynamodb.model.PutRequest;
import software.amazon.awssdk.services.dynamodb.model.ResourceInUseException;
import software.amazon.awssdk.services.dynamodb.model.ScalarAttributeType;
import software.amazon.awssdk.services.dynamodb.model.StreamViewType;
import software.amazon.awssdk.services.dynamodb.model.WriteRequest;

/** Creates the local table and runs standalone DynamoDB examples. */
public final class DynamoAdmin {
    private static final int PAGE_SIZE = 100;
    private static final int MAX_BENCHMARK_ROWS = 20_000;
    private static final int MAX_BATCH_ATTEMPTS = 6;

    private DynamoAdmin() {
    }

    public static void main(String[] args) throws InterruptedException {
        if (args.length == 0) {
            throw new IllegalArgumentException("Use init, purge ID VERSION, gsi CATEGORY [LIMIT], bulk-demo, "
                + "atomic-demo, or benchmark COUNT");
        }
        var settings = Settings.fromEnvironment();
        if (!settings.local() || !(settings.mode().equals("dynamodb") || settings.mode().equals("hybrid"))) {
            throw new IllegalArgumentException("DynamoAdmin requires local DynamoDB or Hybrid mode");
        }
        try (var client = client(settings)) {
            var repo = new DynamoRepository(client, settings);
            switch (args[0]) {
                case "init" -> initialize(client, settings.table(), settings.mode().equals("dynamodb"),
                    settings.mode().equals("hybrid"));
                case "purge" -> purge(repo, args);
                case "gsi" -> gsi(repo, settings, args);
                case "bulk-demo" -> withFixture(client, settings.table(), table -> bulkDemo(client, table));
                case "atomic-demo" -> withFixture(client, settings.table(), table -> atomicDemo(client, table));
                case "benchmark" -> {
                    if (args.length != 2) {
                        throw new IllegalArgumentException("Use benchmark COUNT");
                    }
                    int count = Integer.parseInt(args[1]);
                    if (count < 10 || count > MAX_BENCHMARK_ROWS) {
                        throw new IllegalArgumentException("Benchmark count must be 10 to " + MAX_BENCHMARK_ROWS);
                    }
                    withFixture(client, settings.table(), singleTable -> withFixture(client, settings.table(),
                        batchTable -> benchmark(client, singleTable, batchTable, count)));
                }
                default -> throw new IllegalArgumentException("Unknown DynamoAdmin command: " + args[0]);
            }
        }
    }

    private static void initialize(DynamoDbClient client, String table, boolean indexed, boolean streams) {
        var attributes = new ArrayList<AttributeDefinition>();
        attributes.add(attribute("id"));
        if (indexed) {
            attributes.addAll(List.of(attribute("listPk"), attribute("categoryPk"), attribute("listSk")));
        }
        try {
            client.createTable(request -> {
                request.tableName(table).billingMode(BillingMode.PAY_PER_REQUEST)
                    .attributeDefinitions(attributes).keySchema(keySchema("id", KeyType.HASH));
                if (indexed) {
                    request.globalSecondaryIndexes(index(ALL_INDEX, "listPk"), index(CATEGORY_INDEX, "categoryPk"));
                }
                if (streams) {
                    request.streamSpecification(spec -> spec.streamEnabled(true)
                        .streamViewType(StreamViewType.NEW_AND_OLD_IMAGES));
                }
            });
        } catch (ResourceInUseException ex) {
            // Repeated initialization checks that this table belongs to the selected mode.
        }
        var existing = client.describeTable(request -> request.tableName(table)).table();
        var expectedIndexes = indexed ? Map.of(ALL_INDEX, "listPk", CATEGORY_INDEX, "categoryPk") : Map.<String, String>of();
        var currentIndexes = existing.globalSecondaryIndexes();
        boolean indexesMatch = currentIndexes.size() == expectedIndexes.size() && currentIndexes.stream()
            .allMatch(gsi -> expectedIndexes.containsKey(gsi.indexName())
                && gsi.keySchema().equals(List.of(keySchema(expectedIndexes.get(gsi.indexName()), KeyType.HASH),
                    keySchema("listSk", KeyType.RANGE)))
                && gsi.projection().projectionType() == ProjectionType.ALL);
        boolean streamMatches = streams
            ? existing.streamSpecification() != null
                && Boolean.TRUE.equals(existing.streamSpecification().streamEnabled())
                && existing.streamSpecification().streamViewType() == StreamViewType.NEW_AND_OLD_IMAGES
            : existing.streamSpecification() == null || !Boolean.TRUE.equals(existing.streamSpecification().streamEnabled());
        if (!existing.keySchema().equals(List.of(keySchema("id", KeyType.HASH)))
            || !indexesMatch || !streamMatches) {
            throw new IllegalStateException("DynamoDB Local table schema does not match the selected mode: " + table);
        }
    }

    private static AttributeDefinition attribute(String name) {
        return AttributeDefinition.builder().attributeName(name).attributeType(ScalarAttributeType.S).build();
    }

    private static KeySchemaElement keySchema(String name, KeyType type) {
        return KeySchemaElement.builder().attributeName(name).keyType(type).build();
    }

    private static GlobalSecondaryIndex index(String name, String partition) {
        return GlobalSecondaryIndex.builder().indexName(name)
            .keySchema(keySchema(partition, KeyType.HASH), keySchema("listSk", KeyType.RANGE))
            .projection(projection -> projection.projectionType(ProjectionType.ALL)).build();
    }

    private static void purge(DynamoRepository repo, String[] args) {
        if (args.length != 3 || !UUID.fromString(args[1]).toString().equals(args[1])) {
            throw new IllegalArgumentException("Use purge ID VERSION");
        }
        long version = Long.parseLong(args[2]);
        var current = repo.get(args[1]).orElseThrow(() -> new IllegalStateException("Product does not exist"));
        require(current.version() == version && repo.purge(current, version), "Product changed before purge");
        System.out.printf("purged id=%s version=%d%n", current.id(), version);
    }

    private static void gsi(DynamoRepository repo, Settings settings, String[] args) {
        if (!settings.mode().equals("dynamodb") || args.length < 2 || args.length > 3
            || !args[1].matches("[a-z0-9][a-z0-9-]{0,39}")) {
            throw new IllegalArgumentException("Use gsi CATEGORY [LIMIT] in dynamodb mode");
        }
        int limit = args.length == 3 ? Integer.parseInt(args[2]) : 10;
        if (limit < 1 || limit > PAGE_SIZE) {
            throw new IllegalArgumentException("LIMIT must be between 1 and 100");
        }
        var page = repo.list(args[1], limit, null);
        page.items().forEach(product -> System.out.printf("%s %s %s%n", product.id(), product.category(), product.name()));
        System.out.printf("returned=%d hasNext=%b%n", page.items().size(), page.cursor() != null);
    }

    @FunctionalInterface
    private interface FixtureAction {
        void run(String table) throws InterruptedException;
    }

    private static void withFixture(DynamoDbClient client, String sourceTable, FixtureAction action)
        throws InterruptedException {
        // Leave 45 of the 255 characters for the fixture suffix and its UUID.
        String fixture = sourceTable.substring(0, Math.min(sourceTable.length(), 210)) + "-example-" + UUID.randomUUID();
        initialize(client, fixture, true, false);
        try {
            action.run(fixture);
        } finally {
            client.deleteTable(request -> request.tableName(fixture));
        }
    }

    private static Product exampleProduct(int row) {
        var now = Instant.now();
        return new Product(UUID.randomUUID().toString(), "Product " + row, row % 10 == 0 ? "selected" : "other",
            row, "ACTIVE", 1, now, now, false);
    }

    private static Product renamed(Product original, String name) {
        return new Product(original.id(), name, original.category(), original.priceMinor(), original.status(),
            original.version() + 1, original.createdAt(), Instant.now(), original.deleted());
    }

    private static WriteRequest put(Product product) {
        return WriteRequest.builder().putRequest(PutRequest.builder().item(encode(product, true)).build()).build();
    }

    private static void bulkDemo(DynamoDbClient client, String table) throws InterruptedException {
        var first = exampleProduct(0);
        var second = exampleProduct(1);
        var renamed = renamed(first, "Updated product");
        var repo = new DynamoRepository(client, table, true);
        // DynamoDB Local generally does not throttle. Hold back the second write on the first attempt
        // to exercise the same pending-list behavior without mocking either write to DynamoDB.
        var firstSubmission = new AtomicBoolean(true);
        batch(List.of(put(first), put(second)), "register", requests -> {
            if (firstSubmission.getAndSet(false)) {
                var pending = new ArrayList<>(submitBatch(client, table, requests.subList(0, 1)));
                pending.add(requests.get(1));
                return pending;
            }
            return submitBatch(client, table, requests);
        });
        require(repo.get(first.id()).orElseThrow().equals(first) && repo.get(second.id()).orElseThrow().equals(second),
            "Batch register did not persist both products");

        // BatchWriteItem replaces a whole item; it cannot attach the CRUD repository's version condition.
        batch(client, table, List.of(put(renamed)), "replace");
        require(repo.get(first.id()).orElseThrow().equals(renamed), "Batch replace did not persist");
        var deletion = WriteRequest.builder().deleteRequest(DeleteRequest.builder().key(key(second.id())).build()).build();
        batch(client, table, List.of(deletion), "delete");
        require(repo.get(second.id()).isEmpty(), "Batch delete did not remove the product");
    }

    private static void atomicDemo(DynamoDbClient client, String table) {
        var repo = new DynamoRepository(client, table, true);
        var first = exampleProduct(0);
        var second = exampleProduct(1);
        require(repo.create(first) && repo.create(second), "Failed to create fixtures");
        var changes = List.of(renamed(first, "Updated first"), renamed(second, "Updated second"));
        require(!repo.replaceAtomically(changes, List.of(1L, 2L)), "Stale transaction unexpectedly succeeded");
        require(repo.get(first.id()).orElseThrow().equals(first) && repo.get(second.id()).orElseThrow().equals(second),
            "A stale transaction did not roll back both updates");
        require(repo.replaceAtomically(changes, List.of(1L, 1L)), "Current transaction unexpectedly failed");
        require(repo.get(first.id()).orElseThrow().equals(changes.get(0))
                && repo.get(second.id()).orElseThrow().equals(changes.get(1)),
            "Transaction did not update both products");
        System.out.println("transaction stale-version rolled back; current versions committed both updates");
    }

    private static void batch(DynamoDbClient client, String table, List<WriteRequest> writes, String label)
        throws InterruptedException {
        batch(writes, label, requests -> submitBatch(client, table, requests));
    }

    private static List<WriteRequest> submitBatch(DynamoDbClient client, String table, List<WriteRequest> requests) {
        return client.batchWriteItem(request -> request.requestItems(Map.of(table, requests)))
            .unprocessedItems().getOrDefault(table, List.of());
    }

    private static void batch(List<WriteRequest> writes, String label, Function<List<WriteRequest>, List<WriteRequest>> submit)
        throws InterruptedException {
        for (int offset = 0; offset < writes.size(); offset += 25) {
            var pending = writes.subList(offset, Math.min(offset + 25, writes.size()));
            for (int attempt = 0; attempt < MAX_BATCH_ATTEMPTS && !pending.isEmpty(); attempt++) {
                if (attempt > 0) {
                    Thread.sleep(ThreadLocalRandom.current().nextLong(1L << (attempt + 4)));
                }
                pending = submit.apply(pending);
                if (!pending.isEmpty()) {
                    System.err.printf("%s chunkOffset=%d attempt=%d unprocessed=%d%n", label, offset, attempt + 1,
                        pending.size());
                }
            }
            if (!pending.isEmpty()) {
                throw new IllegalStateException("Batch retry exhausted after " + (offset + Math.min(25, writes.size() - offset)
                    - pending.size()) + " processed requests out of " + writes.size());
            }
        }
        if (!label.equals("benchmark")) {
            System.out.printf("%s processed=%d%n", label, writes.size());
        }
    }

    private static void benchmark(DynamoDbClient client, String singleTable, String batchTable, int count)
        throws InterruptedException {
        var rows = new ArrayList<Product>(count);
        for (int i = 0; i < count; i++) {
            rows.add(exampleProduct(i));
        }
        var requests = rows.stream().map(DynamoAdmin::put).toList();
        long start = System.nanoTime();
        for (var request : requests) {
            client.putItem(builder -> builder.tableName(singleTable).item(request.putRequest().item()));
        }
        double singleMs = elapsedMilliseconds(start);

        // The same product images are inserted into two distinct empty tables with identical indexes.
        start = System.nanoTime();
        batch(client, batchTable, requests, "benchmark");
        double batchMs = elapsedMilliseconds(start);

        var repo = new DynamoRepository(client, batchTable, true);
        int expected = (count + 9) / 10;
        long deadline = System.nanoTime() + Duration.ofSeconds(15).toNanos();
        int queryCount;
        do {
            queryCount = query(repo);
            if (queryCount != expected) {
                Thread.sleep(100);
            }
        } while (queryCount != expected && System.nanoTime() < deadline);
        require(queryCount == expected, "Timed out waiting for the GSI fixture");

        start = System.nanoTime();
        queryCount = query(repo);
        double queryMs = elapsedMilliseconds(start);
        start = System.nanoTime();
        var scan = scan(client, batchTable);
        double scanMs = elapsedMilliseconds(start);
        require(queryCount == expected && scan.matched() == expected && scan.examined() == count,
            "Query and Scan returned different counts");
        System.out.printf(java.util.Locale.ROOT,
            "{\"rows\":%d,\"matched\":%d,\"scanned\":%d,\"singleMs\":%.3f,\"batchMs\":%.3f,\"queryMs\":%.3f,\"scanMs\":%.3f}%n",
            count, expected, scan.examined(), singleMs, batchMs, queryMs, scanMs);
    }

    private static int query(DynamoRepository repo) {
        String cursor = null;
        int count = 0;
        do {
            var page = repo.list("selected", PAGE_SIZE, cursor);
            count += page.items().size();
            cursor = page.cursor();
        } while (cursor != null);
        return count;
    }

    private record ScanResult(int matched, int examined) {}

    private static ScanResult scan(DynamoDbClient client, String table) {
        Map<String, AttributeValue> cursor = Map.of();
        int matched = 0;
        int examined = 0;
        int pages = 0;
        do {
            var start = cursor;
            var response = client.scan(query -> {
                query.tableName(table).limit(PAGE_SIZE).filterExpression("#category = :category")
                    .expressionAttributeNames(Map.of("#category", "category"))
                    .expressionAttributeValues(Map.of(":category", string("selected")));
                if (!start.isEmpty()) {
                    query.exclusiveStartKey(start);
                }
            });
            matched += response.count();
            examined += response.scannedCount();
            cursor = response.lastEvaluatedKey();
            if (++pages > MAX_BENCHMARK_ROWS / PAGE_SIZE + 1) {
                throw new IllegalStateException("Scan exceeded the fixture size limit");
            }
        } while (!cursor.isEmpty());
        return new ScanResult(matched, examined);
    }

    private static double elapsedMilliseconds(long start) {
        return (System.nanoTime() - start) / 1_000_000.0;
    }

    private static void require(boolean result, String message) {
        if (!result) {
            throw new IllegalStateException(message);
        }
    }
}
