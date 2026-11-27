package cookbook.batch.dynamodb;

import static cookbook.batch.dynamodb.DynamoCustomer.PK;
import static cookbook.batch.dynamodb.DynamoCustomer.GSI;
import static cookbook.batch.dynamodb.DynamoCustomer.GSI_PK;
import static cookbook.batch.dynamodb.DynamoCustomer.STATUS;
import static cookbook.batch.dynamodb.DynamoCustomer.text;

import java.time.Duration;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.LongAdder;
import software.amazon.awssdk.core.exception.SdkException;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.BatchWriteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.DynamoDbException;
import software.amazon.awssdk.services.dynamodb.model.Put;
import software.amazon.awssdk.services.dynamodb.model.PutRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItem;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItemsRequest;
import software.amazon.awssdk.services.dynamodb.model.TransactionCanceledException;
import software.amazon.awssdk.services.dynamodb.model.WriteRequest;

public final class DynamoRepository {
    public static final String OPERATION_ID = "operation_id";
    private static final String PAYLOAD_HASH = "payload_hash";
    private static final int MAX_BATCH_BYTES = 16 * 1024 * 1024 - 1024;
    private final DynamoDbClient client;
    private final String table;
    private final String operationsTable;
    private final String index;
    private final int maxAttempts;
    private final long retryBudgetNanos;
    private final long requestSpacingNanos;
    private final Runnable afterTransaction;
    private final LongAdder apiCalls = new LongAdder();
    private final LongAdder retries = new LongAdder();
    private final LongAdder unprocessed = new LongAdder();
    private final LongAdder count = new LongAdder();
    private final LongAdder scannedCount = new LongAdder();
    private long nextRequest;

    public DynamoRepository(DynamoDbClient client, String table, String operationsTable,
            int maxAttempts, Duration retryBudget, int requestsPerSecond) {
        this(client, table, operationsTable, GSI, maxAttempts, retryBudget, requestsPerSecond);
    }

    public DynamoRepository(DynamoDbClient client, String table, String operationsTable, String index,
            int maxAttempts, Duration retryBudget, int requestsPerSecond) {
        this(client, table, operationsTable, index, maxAttempts, retryBudget, requestsPerSecond, () -> {});
    }

    DynamoRepository(DynamoDbClient client, String table, String operationsTable,
            int maxAttempts, Duration retryBudget, int requestsPerSecond, Runnable afterTransaction) {
        this(client, table, operationsTable, GSI, maxAttempts, retryBudget, requestsPerSecond, afterTransaction);
    }

    private DynamoRepository(DynamoDbClient client, String table, String operationsTable, String index,
            int maxAttempts, Duration retryBudget, int requestsPerSecond, Runnable afterTransaction) {
        this.client = Objects.requireNonNull(client, "client");
        this.table = Objects.requireNonNull(table, "table");
        this.operationsTable = Objects.requireNonNull(operationsTable, "operationsTable");
        this.index = Objects.requireNonNull(index, "index");
        if (!index.matches("[a-zA-Z0-9_.-]{3,255}") || table.equals(operationsTable) || maxAttempts < 1 || maxAttempts > 20
                || retryBudget.isZero() || retryBudget.isNegative() || requestsPerSecond < 0) {
            throw new IllegalArgumentException("Invalid DynamoDB repository configuration");
        }
        this.maxAttempts = maxAttempts;
        this.retryBudgetNanos = retryBudget.toNanos();
        this.requestSpacingNanos = requestsPerSecond == 0 ? 0 : 1_000_000_000L / requestsPerSecond;
        this.afterTransaction = afterTransaction;
        nextRequest = System.nanoTime();
    }

    public enum ReadMode { QUERY, SCAN }

    public record Read(ReadMode mode, String partition, boolean gsi, String status,
                       boolean consistentRead, int limit) {
        public Read {
            Objects.requireNonNull(mode, "mode");
            if (partition == null || partition.isBlank() || limit < 1 || limit > 10_000
                    || (gsi && (mode != ReadMode.QUERY || consistentRead
                            || status == null || status.isBlank()))) {
                throw new IllegalArgumentException("Invalid DynamoDB read plan");
            }
        }
    }

    public record Page(List<DynamoCustomer> items, Map<String, AttributeValue> lastEvaluatedKey,
                       int count, int scannedCount) {
        public boolean last() {
            return lastEvaluatedKey.isEmpty();
        }
    }

    public record Metrics(long apiCalls, long retries, long unprocessed, long count, long scannedCount) { }

    public Metrics metrics() {
        return new Metrics(apiCalls.sum(), retries.sum(), unprocessed.sum(), count.sum(), scannedCount.sum());
    }

    public Page page(Read read, Map<String, AttributeValue> lastKey) throws InterruptedException {
        beforeRequest();
        var names = new LinkedHashMap<>(Map.of("#pk", PK));
        var values = new LinkedHashMap<>(Map.of(":pk", text(read.partition())));
        String filter = null;
        if (read.status() != null && !read.gsi()) {
            names.put("#status", STATUS);
            values.put(":status", text(read.status()));
            filter = "#status = :status";
        }
        if (read.mode() == ReadMode.SCAN) {
            filter = filter == null ? "#pk = :pk" : "#pk = :pk AND " + filter;
            var request = ScanRequest.builder().tableName(table)
                    .limit(read.limit()).consistentRead(read.consistentRead())
                    .filterExpression(filter).expressionAttributeNames(names).expressionAttributeValues(values);
            if (!lastKey.isEmpty()) {
                request.exclusiveStartKey(lastKey);
            }
            var response = client.scan(request.build());
            return page(response.items(), response.lastEvaluatedKey(), response.count(), response.scannedCount());
        }
        var request = QueryRequest.builder().tableName(table).limit(read.limit())
                .consistentRead(read.consistentRead()).filterExpression(filter);
        if (!lastKey.isEmpty()) {
            request.exclusiveStartKey(lastKey);
        }
        if (read.gsi()) {
            request.indexName(index);
            names.put("#gsi", GSI_PK);
            values.put(":gsi", text(read.status()));
            request.keyConditionExpression("#gsi = :gsi").filterExpression("#pk = :pk");
        } else {
            request.keyConditionExpression("#pk = :pk");
        }
        var response = client.query(request.expressionAttributeNames(names).expressionAttributeValues(values).build());
        return page(response.items(), response.lastEvaluatedKey(), response.count(), response.scannedCount());
    }

    private Page page(List<Map<String, AttributeValue>> items, Map<String, AttributeValue> lastKey,
            int returned, int scanned) {
        count.add(returned);
        scannedCount.add(scanned);
        return new Page(items.stream().map(DynamoCustomer::from).toList(), Map.copyOf(lastKey), returned, scanned);
    }

    /**
     * BatchWrite replaces items. Callers must use a dedicated immutable input generation with
     * a single writer and must not start business updates until delivery is complete.
     */
    public void replaceGenerationBatch(List<DynamoCustomer> batch) throws InterruptedException {
        if (batch.isEmpty() || batch.size() > 25) {
            throw new IllegalArgumentException("DynamoDB BatchWrite requires 1–25 items");
        }
        var keys = new HashSet<DynamoCustomer.Key>();
        int wireBytes = 0;
        var requests = new java.util.ArrayList<WriteRequest>(batch.size());
        for (var customer : batch) {
            if (!keys.add(customer.key())) {
                throw new IllegalArgumentException("Duplicate DynamoDB key in a batch");
            }
            var item = customer.attributes();
            // Six bytes per byte of input conservatively bounds JSON escaping. Include structure overhead.
            wireBytes = Math.addExact(wireBytes, 128 + 6 * DynamoCustomer.estimatedItemBytes(item));
            if (wireBytes > MAX_BATCH_BYTES) {
                throw new IllegalArgumentException("DynamoDB batch can exceed 16 MiB on the wire");
            }
            requests.add(WriteRequest.builder().putRequest(PutRequest.builder().item(item).build()).build());
        }

        List<WriteRequest> pending = requests;
        long started = System.nanoTime();
        for (int attempt = 1; ; attempt++) {
            beforeRequest();
            var timeout = timedRequest(started);
            var response = client.batchWriteItem(BatchWriteItemRequest.builder()
                    .requestItems(Map.of(table, pending))
                    .overrideConfiguration(config -> config.apiCallTimeout(timeout)).build());
            pending = response.unprocessedItems().getOrDefault(table, List.of());
            if (pending.isEmpty()) {
                return;
            }
            unprocessed.add(pending.size());
            if (!retry(attempt, started)) {
                throw new IllegalStateException("DynamoDB batch retry budget expired with "
                        + pending.size() + " unprocessed items");
            }
        }
    }

    /** The marker and the conditional business change are applied in one DynamoDB transaction. */
    public void mutate(DynamoMutation mutation) throws InterruptedException {
        String hash = mutation.payloadHash(table);
        var marker = TransactWriteItem.builder().put(Put.builder().tableName(operationsTable)
                .item(Map.of(OPERATION_ID, text(mutation.operationId()), PAYLOAD_HASH, text(hash)))
                .conditionExpression("attribute_not_exists(#id)")
                .expressionAttributeNames(Map.of("#id", OPERATION_ID)).build()).build();
        var request = TransactWriteItemsRequest.builder()
                .transactItems(marker, mutation.write(table)).build();
        long started = System.nanoTime();
        for (int attempt = 1; ; attempt++) {
            try {
                beforeRequest();
                var timeout = timedRequest(started);
                client.transactWriteItems(request.toBuilder()
                        .overrideConfiguration(config -> config.apiCallTimeout(timeout)).build());
                afterTransaction.run();
                return;
            } catch (SdkException failure) {
                // Recover both response loss and permanent marker collisions via a strongly consistent read.
                Map<String, AttributeValue> existing;
                try {
                    beforeRequest();
                    var timeout = timedRequest(started);
                    existing = client.getItem(GetItemRequest.builder().tableName(operationsTable)
                            .key(Map.of(OPERATION_ID, text(mutation.operationId())))
                            .overrideConfiguration(config -> config.apiCallTimeout(timeout))
                            .consistentRead(true).build()).item();
                } catch (SdkException | IllegalStateException probeFailure) {
                    failure.addSuppressed(probeFailure);
                    throw failure;
                }
                if (!existing.isEmpty()) {
                    if (!hash.equals(DynamoCustomer.string(existing, PAYLOAD_HASH))) {
                        throw new Conflict("DynamoDB operation ID already holds a different payload", failure);
                    }
                    return;
                }
                if (failure instanceof TransactionCanceledException cancelled
                        && cancelled.cancellationReasons().stream()
                        .anyMatch(reason -> "ConditionalCheckFailed".equals(reason.code()))) {
                    throw new Conflict("DynamoDB expected version or insert-only condition failed", failure);
                }
                boolean retryable = failure.retryable()
                        || (failure instanceof DynamoDbException service
                                && (service.statusCode() >= 500 || service.isThrottlingException()))
                        || (failure instanceof TransactionCanceledException cancelled
                        && cancelled.cancellationReasons().stream().anyMatch(reason ->
                                "TransactionConflict".equals(reason.code())
                                || "ProvisionedThroughputExceeded".equals(reason.code())
                                || "ThrottlingError".equals(reason.code())));
                if (!retryable || !retry(attempt, started)) {
                    throw failure;
                }
            }
        }
    }

    public static final class Conflict extends RuntimeException {
        Conflict(String message, Throwable cause) {
            super(message, cause);
        }
    }

    private Duration timedRequest(long started) {
        long remaining = retryBudgetNanos - (System.nanoTime() - started);
        if (remaining <= 0) {
            throw new IllegalStateException("DynamoDB retry budget expired");
        }
        return Duration.ofNanos(Math.min(remaining, TimeUnit.SECONDS.toNanos(10)));
    }

    private boolean retry(int attempt, long start) throws InterruptedException {
        long remaining = retryBudgetNanos - (System.nanoTime() - start);
        if (attempt >= maxAttempts || remaining <= 0) {
            return false;
        }
        long boundMs = Math.min(1000, 25L << Math.min(attempt - 1, 10));
        long pause = TimeUnit.MILLISECONDS.toNanos(ThreadLocalRandom.current().nextLong(1, boundMs + 1));
        if (pause >= remaining) {
            return false;
        }
        retries.increment();
        TimeUnit.NANOSECONDS.sleep(pause);
        return true;
    }

    private void beforeRequest() throws InterruptedException {
        if (Thread.currentThread().isInterrupted()) {
            throw new InterruptedException("DynamoDB processing stopped");
        }
        rateLimit();
        apiCalls.increment();
    }

    private void rateLimit() throws InterruptedException {
        if (requestSpacingNanos == 0) {
            return;
        }
        long delay;
        synchronized (this) {
            long now = System.nanoTime();
            delay = Math.max(0, nextRequest - now);
            nextRequest = now + delay + requestSpacingNanos;
        }
        TimeUnit.NANOSECONDS.sleep(delay);
    }
}
