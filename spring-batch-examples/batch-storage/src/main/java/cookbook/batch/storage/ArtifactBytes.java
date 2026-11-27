package cookbook.batch.storage;

public record ArtifactBytes(long rows, long size, String sha256) {
    public ArtifactBytes {
        if (rows < 0 || size < 0 || sha256 == null || !sha256.matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("Artifact counts and SHA-256 must be valid");
        }
    }
}
