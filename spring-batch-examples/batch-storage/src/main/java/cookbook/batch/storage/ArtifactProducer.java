package cookbook.batch.storage;

import java.io.OutputStream;

@FunctionalInterface
public interface ArtifactProducer {
    // Close or finish compression before returning the produced row count.
    long writeTo(OutputStream stream) throws Exception;
}
