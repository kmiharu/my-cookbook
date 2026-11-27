package cookbook.batch.file;

import java.io.BufferedInputStream;
import java.io.EOFException;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Objects;
import java.util.zip.CRC32;
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream;

/** Validates every member and bounds the optional gzip header fields before decompression. */
final class StrictGzipInputStream extends InputStream {
    private static final int MAX_TEXT_HEADER_BYTES = 8_192;
    private static final int MAX_HEADER_BYTES = 10 + 2 + 65_535 + 2 * MAX_TEXT_HEADER_BYTES + 2;

    private final BufferedInputStream input;
    private final byte[] one = new byte[1];
    private InputStream member;
    private boolean started;
    private boolean end;

    StrictGzipInputStream(InputStream storedBytes) {
        // A stored-byte digest must see each byte exactly once, outside all mark/reset operations.
        input = new BufferedInputStream(storedBytes);
    }

    @Override
    public int read() throws IOException {
        return read(one, 0, 1) < 0 ? -1 : one[0] & 0xff;
    }

    @Override
    public int read(byte[] bytes, int offset, int length) throws IOException {
        Objects.checkFromIndexSize(offset, length, bytes.length);
        if (length == 0) {
            return 0;
        }
        while (!end) {
            if (member == null) {
                member = openMember();
                if (member == null) {
                    end = true;
                    break;
                }
            }
            int count = member.read(bytes, offset, length);
            if (count >= 0) {
                return count;
            }
            member.close();
            member = null;
        }
        return -1;
    }

    private InputStream openMember() throws IOException {
        input.mark(MAX_HEADER_BYTES);
        int first = input.read();
        if (first < 0) {
            if (!started) {
                throw new EOFException("gzip input is empty");
            }
            return null;
        }
        validateHeader(first);
        input.reset();
        started = true;
        // The inner reader leaves its input at the next member when mark/reset is available.
        return GzipCompressorInputStream.builder()
                .setInputStream(new FilterInputStream(input) {
                    @Override
                    public void close() {
                        // The outer stream owns the compressed input across members.
                    }
                })
                .setDecompressConcatenated(false)
                .get();
    }

    private void validateHeader(int first) throws IOException {
        CRC32 crc = new CRC32();
        crc.update(first);
        if (first != 0x1f || headerByte(crc) != 0x8b || headerByte(crc) != 8) {
            throw new IOException("invalid gzip member signature");
        }
        int flags = headerByte(crc);
        if ((flags & 0xe0) != 0) {
            throw new IOException("invalid gzip member flags");
        }
        for (int index = 0; index < 6; index++) {
            headerByte(crc);
        }
        if ((flags & 4) != 0) {
            int extra = headerByte(crc) | headerByte(crc) << 8;
            for (int index = 0; index < extra; index++) {
                headerByte(crc);
            }
        }
        if ((flags & 8) != 0) {
            consumeText(crc);
        }
        if ((flags & 16) != 0) {
            consumeText(crc);
        }
        if ((flags & 2) != 0) {
            int expected = nextByte() | nextByte() << 8;
            if (expected != (crc.getValue() & 0xffff)) {
                throw new IOException("invalid gzip header checksum");
            }
        }
    }

    private void consumeText(CRC32 crc) throws IOException {
        for (int index = 0; index < MAX_TEXT_HEADER_BYTES; index++) {
            if (headerByte(crc) == 0) {
                return;
            }
        }
        throw new IOException("gzip filename or comment exceeds the header limit");
    }

    private int headerByte(CRC32 crc) throws IOException {
        int next = nextByte();
        crc.update(next);
        return next;
    }

    private int nextByte() throws IOException {
        int next = input.read();
        if (next < 0) {
            throw new EOFException("truncated gzip member header");
        }
        return next;
    }

    @Override
    public void close() throws IOException {
        try (InputStream compressed = input; InputStream current = member) {
            // Release both the inflater and compressed input.
        }
    }
}
