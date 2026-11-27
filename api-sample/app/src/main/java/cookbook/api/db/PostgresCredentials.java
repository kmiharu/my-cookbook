package cookbook.api.db;

import cookbook.api.Settings;
import io.micronaut.core.type.Argument;
import io.micronaut.json.JsonMapper;
import java.io.IOException;
import java.time.Duration;
import java.util.Map;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;

record PostgresCredentials(String username, String password) {
    static PostgresCredentials load(Settings settings) {
        if (settings.local()) {
            return new PostgresCredentials(settings.pgUser(), settings.pgPassword());
        }
        try (SecretsManagerClient secrets = SecretsManagerClient.builder()
                .httpClientBuilder(UrlConnectionHttpClient.builder())
                .overrideConfiguration(builder -> builder.apiCallTimeout(Duration.ofSeconds(6)))
                .build()) {
            String json = secrets.getSecretValue(
                    GetSecretValueRequest.builder().secretId(settings.pgSecretArn()).build()
            ).secretString();
            if (json == null) {
                throw new IllegalStateException("PostgreSQL secret must contain username and password JSON");
            }
            Map<String, Object> fields = JsonMapper.createDefault()
                    .readValue(json, Argument.mapOf(String.class, Object.class));
            if (fields == null || !(fields.get("username") instanceof String user) || user.isBlank()
                    || !(fields.get("password") instanceof String password) || password.isEmpty()) {
                throw new IllegalStateException("PostgreSQL secret must contain username and password JSON");
            }
            return new PostgresCredentials(user, password);
        } catch (IOException e) {
            throw new IllegalStateException("Cannot decode PostgreSQL secret JSON");
        }
    }

    @Override
    public String toString() {
        return "PostgresCredentials[redacted]";
    }
}
