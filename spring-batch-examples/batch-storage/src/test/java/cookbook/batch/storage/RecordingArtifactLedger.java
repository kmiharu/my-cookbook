package cookbook.batch.storage;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

final class RecordingArtifactLedger implements ArtifactLedger {
    private final Map<ArtifactTarget, Entry> entries = new ConcurrentHashMap<>();

    @Override
    public Optional<Entry> find(ArtifactTarget target) {
        return Optional.ofNullable(entries.get(target));
    }

    @Override
    public void uploading(ArtifactTarget target, String uploadId) {
        entries.compute(target, (key, prior) -> new Entry(
                prior == null ? null : prior.bytes(), uploadId, null, false));
    }

    @Override
    public void expected(ArtifactTarget target, ArtifactBytes bytes) {
        entries.compute(target, (key, prior) -> new Entry(bytes, prior.uploadId(), null, false));
    }

    @Override
    public void completed(ArtifactTarget target, ArtifactBytes bytes, String versionId) {
        if (!entries.get(target).bytes().equals(bytes)) {
            throw new IllegalStateException("Publication must match the durable expected bytes");
        }
        entries.put(target, new Entry(bytes, null, versionId, true));
    }

    @Override
    public void failed(ArtifactTarget target, String reason) {
        // Keep bytes and upload identity for the next attempt.
    }
}
