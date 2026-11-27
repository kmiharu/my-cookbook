package cookbook.api;

import java.util.List;
import java.util.Optional;

/** The API can use different adapters for the product store and the listing. */
public interface Repository {
    /** Returns false if the ID has already been used. */
    boolean create(Product product);

    Optional<Product> get(String id);

    /** Atomically saves the replacement if the stored product is undeleted and has the expected version. */
    boolean replace(Product product, long expectedVersion);

    Page list(String category, int limit, String cursor);

    record Page(List<Product> items, String cursor) {}
}
