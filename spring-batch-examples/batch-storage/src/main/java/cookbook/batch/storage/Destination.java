package cookbook.batch.storage;

import java.util.Objects;
import software.amazon.awssdk.services.s3.S3Client;

public record Destination(String id, String bucket, String prefix, S3Client client) {
    public Destination {
        if (id == null || id.isBlank() || bucket == null || bucket.isBlank()) {
            throw new IllegalArgumentException("Destination id and bucket are required");
        }
        prefix = Objects.requireNonNullElse(prefix, "").strip();
        if (prefix.startsWith("/") || prefix.contains("//")) {
            throw new IllegalArgumentException("Destination prefix must be relative");
        }
        Objects.requireNonNull(client, "client");
    }

    public String key(String relativeKey) {
        if (relativeKey == null || relativeKey.isBlank() || relativeKey.startsWith("/")
                || relativeKey.contains("//")) {
            throw new IllegalArgumentException("Artifact key must be relative");
        }
        if (prefix.isEmpty()) {
            return relativeKey;
        }
        return prefix.endsWith("/") ? prefix + relativeKey : prefix + "/" + relativeKey;
    }
}
