package cookbook.api.db;

import cookbook.api.Product;
import cookbook.api.Settings;
import java.net.URI;
import java.time.Instant;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.streams.DynamoDbStreamsClient;

public final class DynamoSupport {
    static final String ALL_INDEX = "all-products";
    static final String CATEGORY_INDEX = "products-by-category";
    static final String ALL_PARTITION = "ALL";
    static final String PURGE_PREFIX = "purge#";
    private static final DateTimeFormatter SORT_DATE = new DateTimeFormatterBuilder().appendInstant(9).toFormatter();

    private DynamoSupport() {
    }

    public static DynamoDbClient client(Settings settings) {
        var builder = DynamoDbClient.builder().httpClientBuilder(httpClient(settings));
        if (settings.local()) {
            builder.endpointOverride(requiredEndpoint(settings.dynamoEndpoint()))
                .region(Region.US_EAST_1).credentialsProvider(dummyCredentials());
        }
        return builder.build();
    }

    public static DynamoDbStreamsClient streams(Settings settings) {
        var builder = DynamoDbStreamsClient.builder().httpClientBuilder(httpClient(settings));
        if (settings.local()) {
            builder.endpointOverride(requiredEndpoint(settings.streamsEndpoint()))
                .region(Region.US_EAST_1).credentialsProvider(dummyCredentials());
        }
        return builder.build();
    }

    private static UrlConnectionHttpClient.Builder httpClient(Settings settings) {
        var builder = UrlConnectionHttpClient.builder();
        if (settings.local()) {
            builder.proxyConfiguration(proxy -> proxy.useEnvironmentVariablesValues(false).useSystemPropertyValues(false));
        }
        return builder;
    }

    private static URI requiredEndpoint(URI endpoint) {
        return Objects.requireNonNull(endpoint, "An explicit DynamoDB Local endpoint is required");
    }

    private static StaticCredentialsProvider dummyCredentials() {
        return StaticCredentialsProvider.create(AwsBasicCredentials.create("local", "local"));
    }

    static Map<String, AttributeValue> encode(Product product, boolean indexed) {
        Map<String, AttributeValue> item = new HashMap<>();
        item.put("id", string(product.id()));
        item.put("name", string(product.name()));
        item.put("category", string(product.category()));
        item.put("priceMinor", number(product.priceMinor()));
        item.put("status", string(product.status()));
        item.put("version", number(product.version()));
        item.put("createdAt", string(product.createdAt().toString()));
        item.put("updatedAt", string(product.updatedAt().toString()));
        item.put("deleted", AttributeValue.fromBool(product.deleted()));
        if (indexed && !product.deleted()) {
            item.put("listPk", string(ALL_PARTITION));
            item.put("categoryPk", string(product.category()));
            item.put("listSk", string(sortKey(product)));
        }
        return item;
    }

    private static String sortKey(Product product) {
        return SORT_DATE.format(product.createdAt()) + "#" + product.id();
    }

    static Map<String, AttributeValue> purgeMarker(Product product) {
        var item = encode(product, false);
        item.put("id", string(PURGE_PREFIX + product.id()));
        item.put("productId", string(product.id()));
        item.put("deleted", AttributeValue.fromBool(true));
        return item;
    }

    public static boolean isPurgeMarker(Map<String, AttributeValue> item) {
        return item.containsKey("id") && item.get("id").s().startsWith(PURGE_PREFIX);
    }

    public static Product decode(Map<String, AttributeValue> item) {
        String id = isPurgeMarker(item) ? item.get("productId").s() : item.get("id").s();
        return new Product(id, item.get("name").s(), item.get("category").s(),
            Long.parseLong(item.get("priceMinor").n()), item.get("status").s(),
            Long.parseLong(item.get("version").n()), Instant.parse(item.get("createdAt").s()),
            Instant.parse(item.get("updatedAt").s()), item.get("deleted").bool());
    }

    static Map<String, AttributeValue> key(String id) {
        return Map.of("id", string(id));
    }

    static AttributeValue string(String value) {
        return AttributeValue.fromS(value);
    }

    static AttributeValue number(long value) {
        return AttributeValue.fromN(Long.toString(value));
    }
}
