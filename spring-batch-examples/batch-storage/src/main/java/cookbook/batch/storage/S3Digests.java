package cookbook.batch.storage;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import software.amazon.awssdk.services.s3.S3Client;

final class S3Digests {
    private S3Digests() {}

    static MessageDigest newSha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 provider unavailable", e);
        }
    }

    static String artifactIdentity(ArtifactTarget target) {
        MessageDigest digest = newSha256();
        for (String value : List.of(target.runId(), target.artifactId(), target.destination(),
                target.bucket(), target.key())) {
            byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
            digest.update(ByteBuffer.allocate(Integer.BYTES).putInt(bytes.length).array());
            digest.update(bytes);
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    static String read(S3Client client, InputObjectVersion current) throws IOException {
        MessageDigest digest = newSha256();
        byte[] buffer = new byte[64 * 1024];
        try (var input = InputObjects.open(client, current)) {
            long bytes = 0;
            try {
                for (int count; (count = input.read(buffer)) != -1; ) {
                    if (Thread.currentThread().isInterrupted()) {
                        throw new InterruptedIOException("Interrupted verifying an S3 artifact");
                    }
                    digest.update(buffer, 0, count);
                    bytes += count;
                }
            } catch (IOException | RuntimeException e) {
                input.abort();
                throw e;
            }
            if (bytes != current.size()) {
                throw new IOException("S3 object length changed during verification");
            }
        }
        return HexFormat.of().formatHex(digest.digest());
    }

}
