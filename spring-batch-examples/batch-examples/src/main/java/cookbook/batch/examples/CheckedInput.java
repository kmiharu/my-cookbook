package cookbook.batch.examples;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

public final class CheckedInput extends FilterInputStream {
    private final String expected;
    private final long size;
    private final MessageDigest digest;
    private long count;

    CheckedInput(InputStream in, String expected, long size) {
        super(in);
        this.expected = expected;
        this.size = size;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException(ex);
        }
    }

    @Override
    public int read() throws IOException {
        int next = in.read();
        if (next >= 0) {
            digest.update((byte) next);
            count++;
        }
        return next;
    }

    @Override
    public int read(byte[] b, int off, int len) throws IOException {
        int n = in.read(b, off, len);
        if (n > 0) {
            digest.update(b, off, n);
            count += n;
        }
        return n;
    }

    @Override
    public long skip(long n) throws IOException {
        long consumed = 0;
        byte[] buffer = new byte[(int) Math.min(8192, Math.max(0, n))];
        while (consumed < n) {
            int length = read(buffer, 0, (int) Math.min(buffer.length, n - consumed));
            if (length == -1) {
                break;
            }
            consumed += length;
        }
        return consumed;
    }

    public String verify(long pinnedSize) throws IOException {
        String sha256 = HexFormat.of().formatHex(digest.digest());
        if (size != pinnedSize || count != size || !sha256.equals(expected)) {
            throw new IOException("Stored input length or SHA-256 does not match");
        }
        return sha256;
    }
}
