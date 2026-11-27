package cookbook.api.db;

import static cookbook.api.db.DynamoSupport.*;

import cookbook.api.Product;
import cookbook.api.Repository;
import cookbook.api.Settings;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionCheck;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.Delete;
import software.amazon.awssdk.services.dynamodb.model.Put;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItem;
import software.amazon.awssdk.services.dynamodb.model.TransactionCanceledException;

public final class DynamoRepository implements Repository {
    private static final Pattern CURSOR = Pattern.compile(
        "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{9}Z#"
            + "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}");
    private static final String NEW_ID = "attribute_not_exists(#id)";
    private static final Map<String, String> ID_NAME = Map.of("#id", "id");
    private static final String ACTIVE_VERSION = "#version = :expected AND #deleted = :active";
    private static final Map<String, String> ACTIVE_NAMES = Map.of("#version", "version", "#deleted", "deleted");
    private static final Map<String, String> VERSION_NAME = Map.of("#version", "version");
    private final DynamoDbClient client;
    private final String table;
    private final boolean indexed;

    public DynamoRepository(DynamoDbClient client, Settings settings) {
        this(client, settings.table(), settings.mode().equals("dynamodb"));
    }

    DynamoRepository(DynamoDbClient client, String table, boolean indexed) {
        this.client = client;
        this.table = table;
        this.indexed = indexed;
    }

    @Override
    public boolean create(Product product) {
        // The transaction checks the purge marker and inserts the product together so IDs stay reserved after deletion.
        var unusedId = ConditionCheck.builder()
            .tableName(table).key(key(PURGE_PREFIX + product.id())).conditionExpression(NEW_ID)
            .expressionAttributeNames(ID_NAME).build();
        var write = Put.builder().tableName(table).item(encode(product, indexed))
            .conditionExpression(NEW_ID).expressionAttributeNames(ID_NAME).build();
        return transact(List.of(TransactWriteItem.builder().conditionCheck(unusedId).build(),
            TransactWriteItem.builder().put(write).build()));
    }

    @Override
    public Optional<Product> get(String id) {
        var response = client.getItem(request -> request.tableName(table).key(key(id)).consistentRead(true));
        return response.hasItem() ? Optional.of(decode(response.item())) : Optional.empty();
    }

    @Override
    public boolean replace(Product product, long expectedVersion) {
        try {
            client.putItem(request -> request.tableName(table).item(encode(product, indexed))
                .conditionExpression(ACTIVE_VERSION).expressionAttributeNames(ACTIVE_NAMES)
                .expressionAttributeValues(activeVersion(expectedVersion)));
            return true;
        } catch (ConditionalCheckFailedException ex) {
            return false;
        }
    }

    @Override
    public Page list(String category, int limit, String cursor) {
        String partitionKey = category == null ? "listPk" : "categoryPk";
        AttributeValue partitionValue = string(category == null ? ALL_PARTITION : category);
        var request = QueryRequest.builder().tableName(table)
            .indexName(category == null ? ALL_INDEX : CATEGORY_INDEX).scanIndexForward(false)
            .keyConditionExpression("#p = :p").expressionAttributeNames(Map.of("#p", partitionKey))
            .expressionAttributeValues(Map.of(":p", partitionValue)).limit(limit + 1);
        if (cursor != null) {
            if (!CURSOR.matcher(cursor).matches()) {
                throw new IllegalArgumentException("Invalid DynamoDB continuation key");
            }
            String id = cursor.substring(cursor.indexOf('#') + 1);
            request.exclusiveStartKey(Map.of("id", string(id), "listSk", string(cursor), partitionKey, partitionValue));
        }
        var response = client.query(request.build());
        var items = response.items();
        int returned = Math.min(limit, items.size());
        String next = null;
        if (items.size() > limit) {
            next = items.get(returned - 1).get("listSk").s();
        } else if (response.hasLastEvaluatedKey() && !response.lastEvaluatedKey().isEmpty()) {
            next = response.lastEvaluatedKey().get("listSk").s();
        }
        return new Page(items.subList(0, returned).stream().map(DynamoSupport::decode).toList(), next);
    }

    boolean purge(Product product, long expectedVersion) {
        var delete = Delete.builder().tableName(table).key(key(product.id()))
            .conditionExpression("#version = :expected").expressionAttributeNames(VERSION_NAME)
            .expressionAttributeValues(Map.of(":expected", number(expectedVersion))).build();
        var marker = Put.builder().tableName(table).item(purgeMarker(product)).conditionExpression(NEW_ID)
            .expressionAttributeNames(ID_NAME).build();
        return transact(List.of(TransactWriteItem.builder().delete(delete).build(),
            TransactWriteItem.builder().put(marker).build()));
    }

    boolean replaceAtomically(List<Product> products, List<Long> expectedVersions) {
        if (products.isEmpty() || products.size() != expectedVersions.size() || products.size() > 25
            || products.stream().map(Product::id).distinct().count() != products.size()) {
            throw new IllegalArgumentException("Use 1 to 25 distinct products with one expected version each");
        }
        var writes = new java.util.ArrayList<TransactWriteItem>();
        for (int i = 0; i < products.size(); i++) {
            var put = Put.builder().tableName(table).item(encode(products.get(i), indexed))
                .conditionExpression(ACTIVE_VERSION).expressionAttributeNames(ACTIVE_NAMES)
                .expressionAttributeValues(activeVersion(expectedVersions.get(i))).build();
            writes.add(TransactWriteItem.builder().put(put).build());
        }
        return transact(writes);
    }

    private boolean transact(List<TransactWriteItem> writes) {
        try {
            client.transactWriteItems(request -> request.transactItems(writes));
            return true;
        } catch (TransactionCanceledException ex) {
            var codes = ex.cancellationReasons().stream().map(reason -> reason.code()).toList();
            if (codes.contains("ConditionalCheckFailed")
                && codes.stream().allMatch(code -> "None".equals(code) || "ConditionalCheckFailed".equals(code))) {
                return false;
            }
            throw ex;
        }
    }

    private static Map<String, AttributeValue> activeVersion(long expected) {
        return Map.of(":expected", number(expected), ":active", AttributeValue.fromBool(false));
    }
}
