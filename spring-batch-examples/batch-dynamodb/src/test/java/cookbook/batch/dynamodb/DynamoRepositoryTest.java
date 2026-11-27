package cookbook.batch.dynamodb;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.BatchWriteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.BatchWriteItemResponse;
import software.amazon.awssdk.services.dynamodb.model.CancellationReason;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemResponse;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryResponse;
import software.amazon.awssdk.services.dynamodb.model.TransactionCanceledException;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItemsRequest;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItemsResponse;

class DynamoRepositoryTest {
    private static final DynamoCustomer.Key KEY = new DynamoCustomer.Key("fixture", "1");
    private final DynamoDbClient client = mock(DynamoDbClient.class);
    private final DynamoRepository repository = new DynamoRepository(client, "business", "operations",
            4, Duration.ofSeconds(3), 0);

    @Test
    void continuesAfterEmptyPageAndPreservesTypedCheckpoint() throws Exception {
        var key = Map.of("pk", AttributeValue.fromS("日本語"),
                "number", AttributeValue.fromN("523.125"),
                "binary", AttributeValue.fromB(SdkBytes.fromByteArray(new byte[]{0, -1})));
        when(client.query(any(QueryRequest.class)))
                .thenReturn(QueryResponse.builder().count(0).scannedCount(1).lastEvaluatedKey(key).build())
                .thenReturn(QueryResponse.builder().items(customer(KEY).attributes()).count(1).scannedCount(1).build());
        var read = new DynamoRepository.Read(DynamoRepository.ReadMode.QUERY, "fixture", false, "active", true, 1);
        var first = repository.page(read, Map.of());
        assertTrue(first.items().isEmpty());
        assertFalse(first.last());
        var resumed = PageKey.decode(PageKey.encode(first.lastEvaluatedKey()));
        assertEquals(key, resumed);
        var last = repository.page(read, resumed);
        assertTrue(last.last());
        assertEquals(KEY, last.items().getFirst().key());
        var query = ArgumentCaptor.forClass(QueryRequest.class);
        verify(client, times(2)).query(query.capture());
        assertEquals(key, query.getAllValues().getLast().exclusiveStartKey());
        assertEquals(1, repository.metrics().count());
        assertEquals(2, repository.metrics().scannedCount());
    }

    @Test
    void sendsOnlyUnprocessedFromPreviousAttempt() throws Exception {
        when(client.batchWriteItem(any(BatchWriteItemRequest.class)))
                .thenAnswer(invocation -> {
                    BatchWriteItemRequest request = invocation.getArgument(0);
                    return BatchWriteItemResponse.builder().unprocessedItems(
                            Map.of("business", List.of(request.requestItems().get("business").getLast()))).build();
                })
                .thenReturn(BatchWriteItemResponse.builder().build());
        repository.replaceGenerationBatch(List.of(customer(KEY),
                customer(new DynamoCustomer.Key("fixture", "2"))));
        var captured = ArgumentCaptor.forClass(BatchWriteItemRequest.class);
        verify(client, times(2)).batchWriteItem(captured.capture());
        assertEquals(List.of(captured.getAllValues().getFirst().requestItems().get("business").getLast()),
                captured.getAllValues().getLast().requestItems().get("business"));
        assertEquals(1, repository.metrics().unprocessed());
        assertEquals(1, repository.metrics().retries());
    }

    @Test
    void refusesDuplicateKeysBeforeCallingBatchWrite() {
        assertThrows(IllegalArgumentException.class,
                () -> repository.replaceGenerationBatch(List.of(customer(KEY), customer(KEY))));
        verifyNoInteractions(client);
    }

    @Test
    void transactionConflictRetriesButVersionConflictDoesNot() throws Exception {
        var conflict = TransactionCanceledException.builder().cancellationReasons(
                CancellationReason.builder().code("TransactionConflict").build()).build();
        var staleVersion = TransactionCanceledException.builder().cancellationReasons(
                CancellationReason.builder().code("ConditionalCheckFailed").build()).build();
        when(client.transactWriteItems(any(TransactWriteItemsRequest.class)))
                .thenThrow(conflict)
                .thenReturn(TransactWriteItemsResponse.builder().build())
                .thenThrow(staleVersion);
        when(client.getItem(any(GetItemRequest.class))).thenReturn(GetItemResponse.builder().build());
        var operation = new DynamoMutation("op-1", DynamoMutation.Kind.ADD, KEY, 0L, null, BigDecimal.ONE);
        repository.mutate(operation);
        assertThrows(DynamoRepository.Conflict.class, () -> repository.mutate(operation));
        verify(client, times(3)).transactWriteItems(any(TransactWriteItemsRequest.class));
        assertEquals(1, repository.metrics().retries());
    }

    @Test
    void rejectsGsiStrongReadAndUnsupportedTypes() {
        assertThrows(IllegalArgumentException.class, () -> new DynamoRepository.Read(
                DynamoRepository.ReadMode.QUERY, "fixture", true, "ACTIVE", true, 100));
        var attributes = new java.util.HashMap<>(customer(KEY).attributes());
        attributes.put("unmodeled", AttributeValue.fromBool(true));
        assertThrows(IllegalArgumentException.class, () -> DynamoCustomer.from(attributes));
    }

    @Test
    void realTransactionResponseLossIsRecognizedFromMarker() throws Exception {
        var ambiguous = SdkClientException.create("synthetic response loss");
        when(client.transactWriteItems(any(TransactWriteItemsRequest.class)))
                .thenAnswer(invocation -> {
                    TransactWriteItemsRequest request = invocation.getArgument(0);
                    var recorded = request.transactItems().getFirst().put().item();
                    when(client.getItem(any(GetItemRequest.class)))
                            .thenReturn(GetItemResponse.builder().item(recorded).build());
                    throw ambiguous;
                });
        var operation = new DynamoMutation("op-1", DynamoMutation.Kind.ADD, KEY, 0L, null, BigDecimal.ONE);
        repository.mutate(operation);
        verify(client).transactWriteItems(any(TransactWriteItemsRequest.class));
        verify(client).getItem(argThat((GetItemRequest request) -> Boolean.TRUE.equals(request.consistentRead())));
    }

    private static DynamoCustomer customer(DynamoCustomer.Key key) {
        return new DynamoCustomer(key, 0, "active", new BigDecimal("4.125"), DynamoCustomer.Text.absent());
    }
}
