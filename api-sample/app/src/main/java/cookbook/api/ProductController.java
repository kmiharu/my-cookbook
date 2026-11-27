package cookbook.api;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.HttpHeaders;
import io.micronaut.http.HttpResponse;
import io.micronaut.http.HttpStatus;
import io.micronaut.http.annotation.Body;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Delete;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.Header;
import io.micronaut.http.annotation.Patch;
import io.micronaut.http.annotation.Post;
import io.micronaut.http.annotation.Put;
import io.micronaut.http.annotation.QueryValue;
import io.micronaut.scheduling.TaskExecutors;
import io.micronaut.scheduling.annotation.ExecuteOn;
import java.util.Map;
import java.util.regex.Pattern;

@Controller
@ExecuteOn(TaskExecutors.BLOCKING)
final class ProductController {
    private static final Pattern VERSION_ETAG = Pattern.compile("\"([1-9][0-9]{0,18})\"");

    private final ProductService products;

    ProductController(ProductService products) {
        this.products = products;
    }

    @Get("/health")
    Map<String, String> health() {
        return Map.of("status", "UP");
    }

    @Post("/products")
    HttpResponse<Product> create(@Body Map<String, Object> body) {
        Product product = products.create(ProductInput.full(body));
        return HttpResponse.created(product)
                .header(HttpHeaders.LOCATION, "/products/" + product.id())
                .header(HttpHeaders.ETAG, etag(product));
    }

    @Get("/products/{id}")
    HttpResponse<Product> get(String id) {
        return ok(products.get(id));
    }

    @Get("/products{?category,limit,nextToken}")
    ProductService.ProductPage list(@QueryValue @Nullable String category, @QueryValue @Nullable Integer limit,
                                    @QueryValue @Nullable String nextToken) {
        return products.list(category, limit, nextToken);
    }

    @Put("/products/{id}")
    HttpResponse<Product> replace(String id, @Header(HttpHeaders.IF_MATCH) @Nullable String ifMatch,
                                  @Body Map<String, Object> body) {
        long version = expectedVersion(ifMatch);
        ProductInput replacement = ProductInput.full(body);
        return ok(products.update(id, version, replacement));
    }

    @Patch("/products/{id}")
    HttpResponse<Product> patch(String id, @Header(HttpHeaders.IF_MATCH) @Nullable String ifMatch,
                                @Body Map<String, Object> body) {
        long version = expectedVersion(ifMatch);
        ProductInput changes = ProductInput.partial(body);
        return ok(products.update(id, version, changes));
    }

    @Delete("/products/{id}")
    HttpResponse<?> delete(String id, @Header(HttpHeaders.IF_MATCH) @Nullable String ifMatch) {
        Product deleted = products.delete(id, expectedVersion(ifMatch));
        return HttpResponse.noContent().header(HttpHeaders.ETAG, etag(deleted));
    }

    private static HttpResponse<Product> ok(Product product) {
        return HttpResponse.ok(product).header(HttpHeaders.ETAG, etag(product));
    }

    private static String etag(Product product) {
        return "\"" + product.version() + "\"";
    }

    static long expectedVersion(String ifMatch) {
        if (ifMatch == null) {
            throw new ApiProblem(HttpStatus.PRECONDITION_REQUIRED, "IF_MATCH_REQUIRED", "If-Match is required");
        }
        var matcher = VERSION_ETAG.matcher(ifMatch);
        if (matcher.matches()) {
            try {
                return Long.parseLong(matcher.group(1));
            } catch (NumberFormatException ignored) {
                // Report oversized versions as validation failures.
            }
        }
        throw ApiProblem.invalid("If-Match must contain one strong version ETag");
    }
}
