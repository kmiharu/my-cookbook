package cookbook.batch.storage;

public record ArtifactResult(ArtifactTarget target, ArtifactBytes bytes, String versionId) {}
