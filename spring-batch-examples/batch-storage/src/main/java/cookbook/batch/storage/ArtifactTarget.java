package cookbook.batch.storage;

public record ArtifactTarget(String runId, String artifactId, String destination, String bucket, String key) {}
