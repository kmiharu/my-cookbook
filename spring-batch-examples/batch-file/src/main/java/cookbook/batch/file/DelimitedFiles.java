package cookbook.batch.file;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.PushbackInputStream;
import java.nio.charset.CodingErrorAction;
import java.util.Arrays;
import java.util.zip.GZIPOutputStream;

public final class DelimitedFiles {
    private static final byte[] UTF8_BOM = {(byte) 0xEF, (byte) 0xBB, (byte) 0xBF};
    private static final int BUFFER_SIZE = 8192;

    private DelimitedFiles() {
    }

    public static DelimitedReader reader(InputStream storedBytes, FileSettings settings) throws IOException {
        InputStream decoded = storedBytes;
        try {
            decoded = decode(storedBytes, settings);
            PushbackInputStream input = new PushbackInputStream(decoded, UTF8_BOM.length);
            byte[] prefix = input.readNBytes(UTF8_BOM.length);
            boolean hasBom = Arrays.equals(prefix, UTF8_BOM);
            if (hasBom != settings.bom()) {
                throw new IOException(settings.bom() ? "required UTF-8 BOM is missing" : "unexpected UTF-8 BOM");
            }
            if (!hasBom) {
                input.unread(prefix);
            }
            InputStreamReader characters = new InputStreamReader(input, settings.charset().newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT));
            return new DelimitedReader(new BufferedReader(characters, BUFFER_SIZE), settings);
        } catch (IOException | RuntimeException failure) {
            closeOnFailure(decoded, failure);
            throw failure;
        }
    }

    public static DelimitedWriter writer(OutputStream storedBytes, FileSettings settings) throws IOException {
        OutputStream encoded = storedBytes;
        try {
            encoded = encode(storedBytes, settings);
            if (settings.bom()) {
                encoded.write(UTF8_BOM);
            }
            OutputStreamWriter characters = new OutputStreamWriter(encoded, settings.charset().newEncoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT));
            return new DelimitedWriter(new BufferedWriter(characters, BUFFER_SIZE), settings);
        } catch (IOException | RuntimeException failure) {
            closeOnFailure(encoded, failure);
            throw failure;
        }
    }

    /** Reads every gzip member and rejects bytes that do not form a complete member. */
    public static InputStream decode(InputStream storedBytes, FileSettings settings) throws IOException {
        return switch (settings.compression()) {
            case NONE -> storedBytes;
            case GZIP -> new StrictGzipInputStream(storedBytes);
        };
    }

    /** Writes gzip without a timestamp, original filename, or comment. */
    public static OutputStream encode(OutputStream storedBytes, FileSettings settings) throws IOException {
        return switch (settings.compression()) {
            case NONE -> storedBytes;
            case GZIP -> new LevelGzipOutputStream(storedBytes, settings.gzipLevel());
        };
    }

    private static void closeOnFailure(AutoCloseable stream, Exception failure) {
        try {
            stream.close();
        } catch (Exception closing) {
            failure.addSuppressed(closing);
        }
    }

    private static final class LevelGzipOutputStream extends GZIPOutputStream {
        LevelGzipOutputStream(OutputStream output, int level) throws IOException {
            super(output, BUFFER_SIZE);
            def.setLevel(level);
        }
    }
}
