package cookbook.api;

import static org.junit.jupiter.api.Assertions.*;

import io.micronaut.context.annotation.Factory;
import io.micronaut.context.annotation.Property;
import io.micronaut.context.annotation.Replaces;
import io.micronaut.context.annotation.Requires;
import io.micronaut.http.HttpRequest;
import io.micronaut.http.HttpStatus;
import io.micronaut.http.client.HttpClient;
import io.micronaut.http.client.annotation.Client;
import io.micronaut.http.client.exceptions.HttpClientResponseException;
import io.micronaut.test.extensions.junit5.annotation.MicronautTest;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import java.util.Map;
import org.junit.jupiter.api.Test;

@MicronautTest
@Property(name = "cookbook.test-validation", value = "true")
class ProductHttpTest {
    @Inject
    @Client("/")
    HttpClient client;

    @Factory
    @Requires(property = "cookbook.test-validation", value = "true")
    static class ValidationSettings {
        @Singleton
        @Replaces(Settings.class)
        Settings settings() {
            return Settings.from(Map.of("APP_RUNTIME", "local", "DATABASE_TYPE", "dynamodb",
                    "DYNAMODB_TABLE", "test-products", "DYNAMODB_ENDPOINT", "http://localhost:8000"));
        }
    }

    @Test
    void nettyUsesTheCommonErrorAndRequestIdWithoutConnectingToDynamoDb() {
        var request = HttpRequest.GET("/products/not-a-uuid").header("X-Request-Id", "contract-check");
        var failure = assertThrows(HttpClientResponseException.class, () -> client.toBlocking().exchange(request));
        assertEquals(HttpStatus.BAD_REQUEST, failure.getStatus());
        assertEquals("contract-check", failure.getResponse().getHeaders().get("X-Request-Id"));
        String body = failure.getResponse().getBody(String.class).orElseThrow();
        assertTrue(body.contains("INVALID_REQUEST") && body.contains("contract-check"), body);
    }
}
