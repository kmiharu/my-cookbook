package cookbook.api.sync;

import cookbook.api.Product;
import cookbook.api.db.DynamoSupport;
import cookbook.api.db.PostgresRepository;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

import java.util.Map;

final class ProductChanges {
    private ProductChanges() {}

    static void apply(PostgresRepository repository, String operation, Map<String, AttributeValue> image) {
        if (image.isEmpty()) {
            throw new IllegalArgumentException("Stream record is missing its product image");
        }
        if (DynamoSupport.isPurgeMarker(image)) {
            return;
        }

        Product product = DynamoSupport.decode(image);
        switch (operation) {
            case "INSERT", "MODIFY" -> repository.project(product);
            case "REMOVE" -> repository.project(new Product(
                product.id(), product.name(), product.category(), product.priceMinor(), product.status(),
                product.version(), product.createdAt(), product.updatedAt(), true));
            default -> throw new IllegalArgumentException("Unsupported DynamoDB Stream operation: " + operation);
        }
    }
}
