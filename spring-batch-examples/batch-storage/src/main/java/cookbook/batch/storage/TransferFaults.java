package cookbook.batch.storage;

import java.io.IOException;

@FunctionalInterface
public interface TransferFaults {
    TransferFaults NONE = (phase, target, part) -> {};

    void hit(Phase phase, ArtifactTarget target, int part) throws IOException;

    enum Phase {
        UPLOAD_PART,
        EXPECTED_COMMITTED,
        OBJECT_COMPLETE
    }
}
