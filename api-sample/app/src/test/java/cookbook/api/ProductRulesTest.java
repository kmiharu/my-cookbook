package cookbook.api;

import static org.junit.jupiter.api.Assertions.*;

import io.micronaut.http.HttpStatus;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;

class ProductRulesTest {
    @Test
    void validatesStrongVersionEtags() {
        assertEquals(12, ProductController.expectedVersion("\"12\""));
        assertEquals(HttpStatus.PRECONDITION_REQUIRED,
                assertThrows(ApiProblem.class, () -> ProductController.expectedVersion(null)).status());
        for (String invalid : new String[]{"12", "*", "\"0\"", "W/\"12\"", "\"12\", \"13\"", "\"9999999999999999999\""}) {
            assertEquals(HttpStatus.BAD_REQUEST,
                    assertThrows(ApiProblem.class, () -> ProductController.expectedVersion(invalid)).status());
        }
    }

    @Test
    void patchDistinguishesOmissionFromNull() {
        ProductInput patch = ProductInput.partial(Map.of("name", "  名称  "));
        assertEquals("名称", patch.name());
        assertNull(patch.category());
        var explicitNull = new HashMap<String, Object>();
        explicitNull.put("name", null);
        assertThrows(ApiProblem.class, () -> ProductInput.partial(explicitNull));
        assertThrows(ApiProblem.class, () -> ProductInput.full(Map.of("name", "  名称  ")));
        assertThrows(ApiProblem.class, () -> ProductInput.partial(Map.of("priceMinor", 1.5)));
    }

    @Test
    void localSettingsRejectPublicOrImplicitEndpoints() {
        Map<String, String> base = Map.of("APP_RUNTIME", "local", "DATABASE_TYPE", "dynamodb", "DYNAMODB_TABLE", "products");
        var env = new HashMap<>(base);
        assertThrows(IllegalArgumentException.class, () -> Settings.from(env));
        for (String invalid : new String[]{"https://dynamodb.us-east-1.amazonaws.com", "http://localhost",
                "http://localhost:8000?redirect=elsewhere", "http://localhost:0"}) {
            env.put("DYNAMODB_ENDPOINT", invalid);
            assertThrows(IllegalArgumentException.class, () -> Settings.from(env));
        }
        env.put("DYNAMODB_ENDPOINT", "http://localhost:8000");
        assertEquals("localhost", Settings.from(env).dynamoEndpoint().getHost());
        assertNull(Settings.from(env).jdbcUrl());
    }

    @Test
    void auroraSettingsRequireOnlyPostgres() {
        Settings settings = Settings.from(Map.of("APP_RUNTIME", "local", "DATABASE_TYPE", "aurora",
                "PG_JDBC_URL", "jdbc:postgresql://postgres:5432/products",
                "PG_USER", "products", "PG_PASSWORD", "products"));
        assertNull(settings.dynamoEndpoint());
        assertNull(settings.table());
        assertNull(settings.pgSecretArn());
    }
}
