package cookbook.batch.storage;

import java.util.Optional;

public interface ArtifactLedger {
    Optional<Entry> find(ArtifactTarget target);

    // Implement each write as a durable transaction, preserving any existing expected bytes.
    void uploading(ArtifactTarget target, String uploadId);

    void expected(ArtifactTarget target, ArtifactBytes bytes);

    void completed(ArtifactTarget target, ArtifactBytes bytes, String versionId);

    // Preserve prior expected bytes and never downgrade a completed artifact.
    void failed(ArtifactTarget target, String reason);

    record Entry(ArtifactBytes bytes, String uploadId, String versionId, boolean complete) {}
}
