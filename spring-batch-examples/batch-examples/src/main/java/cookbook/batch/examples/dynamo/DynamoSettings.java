package cookbook.batch.examples.dynamo;

import cookbook.batch.dynamodb.DynamoClients;
import cookbook.batch.dynamodb.DynamoRepository;
import java.net.URI;
import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;

@ConfigurationProperties("batch.dynamo")
public record DynamoSettings(
        @DefaultValue("us-east-1") String region,
        @DefaultValue("batch-dynamo-customers") String table,
        @DefaultValue("batch-dynamo-operations") String operationsTable,
        URI endpoint,
        @DefaultValue("by-status") String index,
        @DefaultValue("demo") String partition,
        @DefaultValue("QUERY") String readMode,
        @DefaultValue("100") int pageLimit,
        @DefaultValue("25") int batchSize,
        @DefaultValue("1") int workers,
        @DefaultValue("0") int rateLimit,
        @DefaultValue("4") int retryAttempts,
        @DefaultValue("30") int retrySeconds) {
    public DynamoSettings {
        String awsName = "[a-zA-Z0-9_.-]{3,255}";
        if (!table.matches(awsName) || !operationsTable.matches(awsName) || table.equals(operationsTable)
                || !index.matches(awsName) || region.isBlank() || pageLimit < 1 || pageLimit > 10_000
                || batchSize < 1 || batchSize > 25 || workers < 1 || workers > 8
                || rateLimit < 0 || rateLimit > 100_000 || retryAttempts < 1 || retryAttempts > 10
                || retrySeconds < 1 || retrySeconds > 120) {
            throw new IllegalArgumentException("Invalid DynamoDB settings");
        }
    }

    DynamoDbClient openClient(boolean local, DynamoClients.Metrics metrics) {
        return DynamoClients.open(region, endpoint, local, metrics);
    }

    DynamoRepository repository(DynamoDbClient client, DynamoPlan plan) {
        return new DynamoRepository(client, table, operationsTable, index, plan.retryAttempts(),
                Duration.ofSeconds(plan.retrySeconds()), plan.rateLimit());
    }
}
