package cookbook.api;

import cookbook.api.db.DynamoRepository;
import cookbook.api.db.DynamoSupport;
import cookbook.api.db.PostgresRepository;
import io.micronaut.context.annotation.Context;
import io.micronaut.context.annotation.Factory;
import jakarta.inject.Singleton;
import java.time.Clock;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;

@Context
final class ApplicationDatabase implements AutoCloseable {
    private final DynamoDbClient dynamo;
    private final PostgresRepository postgres;
    private final ProductService products;

    ApplicationDatabase(Settings settings) {
        if (settings.mode().equals("aurora")) {
            dynamo = null;
            postgres = new PostgresRepository(settings);
            products = new ProductService(postgres, postgres, settings.mode(), Clock.systemUTC());
        } else {
            dynamo = DynamoSupport.client(settings);
            try {
                var productStore = new DynamoRepository(dynamo, settings);
                if (settings.mode().equals("hybrid")) {
                    postgres = new PostgresRepository(settings);
                    products = new ProductService(productStore, postgres, settings.mode(), Clock.systemUTC());
                } else {
                    postgres = null;
                    products = new ProductService(productStore, productStore, settings.mode(), Clock.systemUTC());
                }
            } catch (RuntimeException startFailure) {
                dynamo.close();
                throw startFailure;
            }
        }
    }

    @jakarta.annotation.PreDestroy
    @Override
    public void close() {
        try {
            if (postgres != null) {
                postgres.close();
            }
        } finally {
            if (dynamo != null) {
                dynamo.close();
            }
        }
    }

    @Factory
    static class Beans {
        @Singleton
        Settings settings() {
            return Settings.fromEnvironment();
        }

        @Singleton
        ProductService products(ApplicationDatabase database) {
            return database.products;
        }
    }
}
