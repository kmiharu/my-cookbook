package cookbook.api;

import com.fasterxml.jackson.annotation.JsonInclude;
import io.micronaut.http.HttpStatus;
import io.micronaut.serde.annotation.Serdeable;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Base64;
import java.util.List;
import java.util.UUID;

final class ProductService {
    private final Repository productStore;
    private final Repository productListing;
    private final String mode;
    private final Clock clock;

    ProductService(Repository productStore, Repository productListing, String mode, Clock clock) {
        this.productStore = productStore;
        this.productListing = productListing;
        this.mode = mode;
        this.clock = clock;
    }

    Product create(ProductInput input) {
        Instant now = now();
        for (int attempt = 0; attempt < 3; attempt++) {
            Product product = new Product(UUID.randomUUID().toString(), input.name(), input.category(),
                    input.priceMinor(), input.status(), 1, now, now, false);
            if (productStore.create(product)) {
                return product;
            }
        }
        throw new ApiProblem(HttpStatus.CONFLICT, "ID_CONFLICT", "Unable to allocate a unique ID");
    }

    Product get(String id) {
        return productStore.get(ProductInput.id(id))
                .filter(product -> !product.deleted())
                .orElseThrow(ApiProblem::notFound);
    }

    Product update(String id, long expectedVersion, ProductInput input) {
        Product current = get(id);
        long version = nextVersion(current, expectedVersion);

        // A null field in validated input represents a field omitted from PATCH.
        String name = input.name() == null ? current.name() : input.name();
        String category = input.category() == null ? current.category() : input.category();
        long priceMinor = input.priceMinor() == null ? current.priceMinor() : input.priceMinor();
        String status = input.status() == null ? current.status() : input.status();

        Product replacement = new Product(id, name, category, priceMinor, status,
                version, current.createdAt(), now(), false);
        return saveIfCurrent(replacement, expectedVersion);
    }

    Product delete(String id, long expectedVersion) {
        Product current = get(id);
        long version = nextVersion(current, expectedVersion);
        Product deleted = new Product(id, current.name(), current.category(), current.priceMinor(),
                current.status(), version, current.createdAt(), now(), true);
        return saveIfCurrent(deleted, expectedVersion);
    }

    private static long nextVersion(Product current, long expected) {
        if (current.version() != expected) {
            throw ApiProblem.conflict();
        }
        if (expected == Long.MAX_VALUE) {
            throw new ApiProblem(HttpStatus.CONFLICT, "VERSION_EXHAUSTED", "Product version cannot increase");
        }
        return expected + 1;
    }

    private Product saveIfCurrent(Product replacement, long expectedVersion) {
        if (!productStore.replace(replacement, expectedVersion)) {
            // A concurrent delete is reported like any other operation on a deleted product.
            get(replacement.id());
            throw ApiProblem.conflict();
        }
        return replacement;
    }

    ProductPage list(String category, Integer limit, String token) {
        int pageSize = limit == null ? 20 : limit;
        if (pageSize < 1 || pageSize > 100) {
            throw ApiProblem.invalid("limit must be between 1 and 100");
        }
        String filter = category == null ? null : ProductInput.category(category);
        String prefix = "1\n" + mode + "\n" + (filter == null ? "" : filter) + "\n";
        Repository.Page page;
        try {
            page = productListing.list(filter, pageSize, decodeCursor(token, prefix));
        } catch (IllegalArgumentException invalidCursor) {
            if (token == null) {
                throw invalidCursor;
            }
            throw ApiProblem.invalid("Invalid nextToken");
        }
        return new ProductPage(page.items(), page.cursor() == null ? null
                : Base64.getUrlEncoder().withoutPadding().encodeToString(
                        (prefix + page.cursor()).getBytes(StandardCharsets.UTF_8)));
    }

    private static String decodeCursor(String token, String prefix) {
        if (token == null) {
            return null;
        }
        if (token.isEmpty() || token.length() > 4096) {
            throw ApiProblem.invalid("Invalid nextToken");
        }
        try {
            String decoded = new String(Base64.getUrlDecoder().decode(token), StandardCharsets.UTF_8);
            if (decoded.startsWith(prefix) && decoded.length() > prefix.length()) {
                return decoded.substring(prefix.length());
            }
        } catch (IllegalArgumentException ignored) {
            // The same error covers malformed and cross-filter tokens.
        }
        throw ApiProblem.invalid("Invalid nextToken");
    }

    private Instant now() {
        return clock.instant().truncatedTo(ChronoUnit.MILLIS);
    }

    @Serdeable
    @JsonInclude(JsonInclude.Include.ALWAYS)
    public record ProductPage(List<Product> items, String nextToken) {}
}
