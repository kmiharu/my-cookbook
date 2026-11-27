package cookbook.batch.dynamodb;

import static org.junit.jupiter.api.Assertions.*;

import java.math.BigDecimal;
import java.net.URI;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeDefinition;
import software.amazon.awssdk.services.dynamodb.model.GlobalSecondaryIndex;
import software.amazon.awssdk.services.dynamodb.model.KeySchemaElement;
import software.amazon.awssdk.services.dynamodb.model.Projection;

@EnabledIfEnvironmentVariable(named = "BATCH_TEST_DYNAMO_ENDPOINT", matches = "https?://.*")
class DynamoLocalTest {
    @Test
    void validatesRealQueryGsiScanBatchAndIdempotentMutations() throws Exception {
        URI endpoint = URI.create(System.getenv("BATCH_TEST_DYNAMO_ENDPOINT"));
        String suffix = UUID.randomUUID().toString();
        String table = "batch-test-business-" + suffix;
        String operations = "batch-test-operations-" + suffix;
        try (var client = DynamoClients.open("us-east-1", endpoint, true)) {
            create(client, table, operations);
            try {
                var responseLost = new AtomicBoolean();
                var repo = new DynamoRepository(client, table, operations, 4, Duration.ofSeconds(4), 0, () -> {
                    if (responseLost.getAndSet(false)) {
                        throw SdkClientException.create("synthetic response loss after real commit");
                    }
                });
                var key = new DynamoCustomer.Key("fixture", "1");
                var absent = new DynamoCustomer(key, 0, "active", new BigDecimal("1.125"), DynamoCustomer.Text.absent());
                var nullText = new DynamoCustomer(new DynamoCustomer.Key("fixture", "2"), 0,
                        "active", BigDecimal.ZERO, DynamoCustomer.Text.nullable(null));
                var empty = new DynamoCustomer(new DynamoCustomer.Key("fixture", "3"), 0,
                        "blocked", BigDecimal.ZERO, DynamoCustomer.Text.nullable(""));
                repo.replaceGenerationBatch(List.of(absent, nullText, empty));

                var query = new DynamoRepository.Read(DynamoRepository.ReadMode.QUERY, "fixture", false, null, true, 1);
                assertEquals(List.of(absent, nullText, empty), read(repo, query));
                var gsi = new DynamoRepository.Read(DynamoRepository.ReadMode.QUERY, "fixture", true, "active", false, 1);
                assertEquals(List.of(absent, nullText), read(repo, gsi));
                var scan = new DynamoRepository.Read(DynamoRepository.ReadMode.SCAN, "fixture", false, "blocked", false, 1);
                assertEquals(List.of(empty), read(repo, scan));

                var add = new DynamoMutation("add-once", DynamoMutation.Kind.ADD, key, 0, null, BigDecimal.ONE);
                responseLost.set(true);
                repo.mutate(add);
                repo.mutate(add);
                var first = read(repo, query).getFirst();
                assertEquals(new BigDecimal("2.125"), first.balance());
                assertEquals(1, first.version());
                assertThrows(DynamoRepository.Conflict.class, () -> repo.mutate(
                        new DynamoMutation("add-once", DynamoMutation.Kind.ADD, key, 0, null, BigDecimal.TEN)));
                assertThrows(DynamoRepository.Conflict.class, () -> repo.mutate(
                        new DynamoMutation("stale", DynamoMutation.Kind.DELETE, key, 0, null, null)));

                var update = new DynamoCustomer(key, 2, "blocked", first.balance(), DynamoCustomer.Text.nullable("日本語"));
                repo.mutate(new DynamoMutation("update", DynamoMutation.Kind.UPDATE, key, 1, update, null));
                assertEquals(update, read(repo, query).getFirst());
                var delete = new DynamoMutation("delete", DynamoMutation.Kind.DELETE, key, 2, null, null);
                repo.mutate(delete);
                repo.mutate(delete);
                assertEquals(List.of(nullText, empty), read(repo, query));
                var insert = new DynamoMutation("restore-v7", DynamoMutation.Kind.INSERT_ONLY, key, -1,
                        new DynamoCustomer(key, 7, "active", BigDecimal.ZERO, DynamoCustomer.Text.nullable(null)), null);
                repo.mutate(insert);
                assertEquals(7, read(repo, query).getFirst().version());
                assertThrows(DynamoRepository.Conflict.class, () -> repo.mutate(
                        new DynamoMutation("restore-v7", DynamoMutation.Kind.INSERT_ONLY, key, -1,
                                new DynamoCustomer(key, 8, "active", BigDecimal.ZERO,
                                        DynamoCustomer.Text.nullable(null)), null)));
            } finally {
                client.deleteTable(request -> request.tableName(operations));
                client.deleteTable(request -> request.tableName(table));
            }
        }
    }

    private static List<DynamoCustomer> read(DynamoRepository repository, DynamoRepository.Read plan)
            throws InterruptedException {
        var page = repository.page(plan, Map.of());
        var results = new ArrayList<>(page.items());
        while (!page.last()) {
            page = repository.page(plan, PageKey.decode(PageKey.encode(page.lastEvaluatedKey())));
            results.addAll(page.items());
        }
        return results;
    }

    private static void create(DynamoDbClient client, String table, String operations) {
        var pk = key("pk", "HASH");
        var sk = key("sk", "RANGE");
        var gsiPk = key("gsi_pk", "HASH");
        var gsiSk = key("gsi_sk", "RANGE");
        client.createTable(request -> request.tableName(table).billingMode("PAY_PER_REQUEST")
                .attributeDefinitions(definition("pk"), definition("sk"), definition("gsi_pk"), definition("gsi_sk"))
                .keySchema(pk, sk).globalSecondaryIndexes(GlobalSecondaryIndex.builder().indexName("by-status")
                        .keySchema(gsiPk, gsiSk).projection(Projection.builder().projectionType("ALL").build()).build()));
        client.createTable(request -> request.tableName(operations).billingMode("PAY_PER_REQUEST")
                .attributeDefinitions(definition("operation_id")).keySchema(key("operation_id", "HASH")));
        var d = client.describeTable(request -> request.tableName(table)).table();
        assertEquals(List.of(pk, sk), d.keySchema());
        var gsi = d.globalSecondaryIndexes().getFirst();
        assertEquals("by-status", gsi.indexName());
        assertEquals(List.of(gsiPk, gsiSk), gsi.keySchema());
        var op = client.describeTable(request -> request.tableName(operations)).table();
        assertEquals(List.of(key("operation_id", "HASH")), op.keySchema());
    }

    private static KeySchemaElement key(String attribute, String type) {
        return KeySchemaElement.builder().attributeName(attribute).keyType(type).build();
    }

    private static AttributeDefinition definition(String attribute) {
        return AttributeDefinition.builder().attributeName(attribute).attributeType("S").build();
    }
}
