package cookbook.batch.file;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class DelimitedFilesTest {
    @Test
    void roundTripsNullEmptyAndMultilineTsvWithBomAndCrlf() throws IOException {
        FileSettings settings = settings(Map.of("output.format", "tsv", "output.bom", "true",
                "output.lineEnding", "crlf", "output.nullValue", "NULL", "output.quote", "'",
                "output.escape", "backslash"));
        List<String> columns = List.of("id", "空欄", "literal", "notes");
        List<String> row = Arrays.asList(null, "", "NULL", "日本語\t値\n引用符'と\\");
        byte[] bytes = write(settings, columns, row);
        assertEquals("\uFEFFid\t空欄\tliteral\tnotes\r\nNULL\t''\t'NULL'\t'日本語\t値\n引用符\\'と\\\\'\r\n",
                new String(bytes, StandardCharsets.UTF_8));
        try (DelimitedReader reader = DelimitedFiles.reader(new ByteArrayInputStream(bytes), settings)) {
            reader.requireHeader(columns);
            assertEquals(row, reader.read());
            assertNull(reader.read());
        }
    }

    @Test
    void renamesHeaderWithoutChangingColumnPositions() throws IOException {
        FileSettings settings = settings(Map.of("output.columns", "id,name", "output.columnNames", "番号,氏名"));
        List<String> columnOrder = List.of("id", "name");
        byte[] bytes = write(settings, columnOrder, List.of("1", "山田"));
        assertEquals("番号,氏名\n1,山田\n", new String(bytes, StandardCharsets.UTF_8));
        try (DelimitedReader reader = DelimitedFiles.reader(new ByteArrayInputStream(bytes), settings)) {
            reader.requireHeader(columnOrder);
            assertEquals(List.of("1", "山田"), reader.read());
        }
        assertThrows(IllegalArgumentException.class,
                () -> settings(Map.of("output.columns", "id,name", "output.columnNames", "番号")));
    }

    @Test
    void handlesEmptyInputNullEmptyStringEscapingAndMissingFinalNewline() throws IOException {
        try (DelimitedReader reader = reader("", settings(Map.of("output.header", "false")))) {
            assertNull(reader.read());
        }
        try (DelimitedReader reader = reader(",\"\",\"a\"\"b\",\"x\r\ny\"", FileSettings.defaults())) {
            assertEquals(Arrays.asList(null, "", "a\"b", "x\r\ny"), reader.read());
            assertNull(reader.read());
        }
    }

    @Test
    void rejectsMalformedRecordsAndIndependentLimits() {
        FileSettings limited = settings(Map.of("output.maxColumnChars", "3", "output.maxRecordChars", "7",
                "output.maxColumns", "3"));
        assertThrows(IOException.class, () -> read("abcd\n", limited));
        assertThrows(IOException.class, () -> read("abc,def,g\n", limited));
        assertThrows(IOException.class, () -> read("a,b,c,d\n", limited));
        assertThrows(IOException.class, () -> read("\"missing\nending", FileSettings.defaults()));
        assertThrows(IOException.class, () -> read("field\"quote\n", FileSettings.defaults()));
        assertThrows(IOException.class, () -> read("\"field\"tail\n", FileSettings.defaults()));
        assertThrows(IOException.class, () -> read("unexpected CRLF\r\n", FileSettings.defaults()));
    }

    @Test
    void rejectsUnexpectedBomAndHeaderAndReportsCharacterCodingErrors() throws IOException {
        assertThrows(IllegalArgumentException.class, () -> settings(Map.of("output.charset", "Windows-31J",
                "output.bom", "true")));
        assertThrows(IOException.class, () -> read("\uFEFFunexpected", FileSettings.defaults()));
        try (DelimitedReader reader = reader("not,the,header\n", FileSettings.defaults())) {
            assertThrows(IOException.class, () -> reader.requireHeader(List.of("id", "name")));
        }
        FileSettings windows = settings(Map.of("output.charset", "Windows-31J"));
        assertThrows(IOException.class, () -> write(windows, List.of("name"), List.of("😊")));
        assertThrows(IOException.class, () -> write(windows, List.of("name"), List.of("¥")));
        byte[] valid = write(windows, List.of("name"), List.of("日本語"));
        try (DelimitedReader reader = DelimitedFiles.reader(new ByteArrayInputStream(valid), windows)) {
            reader.requireHeader(List.of("name"));
            assertEquals(List.of("日本語"), reader.read());
        }
        byte[] invalid = {(byte) 0xff};
        assertThrows(IOException.class, () -> {
            try (DelimitedReader reader = DelimitedFiles.reader(new ByteArrayInputStream(invalid), FileSettings.defaults())) {
                reader.read();
            }
        });
    }

    @Test
    void validatesEveryGzipMemberWithoutDoubleHashingStoredBytes() throws Exception {
        FileSettings settings = settings(Map.of("output.compression", "gzip", "output.header", "false"));
        byte[] first = write(settings, List.of(), List.of("first"));
        byte[] second = write(settings, List.of(), List.of("second"));
        assertArrayEquals(first, write(settings, List.of(), List.of("first")));
        assertArrayEquals(new byte[4], Arrays.copyOfRange(first, 4, 8));
        byte[] members = concatenate(first, second);
        MessageDigest storedDigest = MessageDigest.getInstance("SHA-256");
        try (DelimitedReader reader = DelimitedFiles.reader(
                new DigestInputStream(new ByteArrayInputStream(members), storedDigest), settings)) {
            assertEquals(List.of("first"), reader.read());
            assertEquals(List.of("second"), reader.read());
            assertNull(reader.read());
        }
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(members), storedDigest.digest());
        assertThrows(IOException.class, () -> drainStored(Arrays.copyOf(first, first.length - 1), settings));
        byte[] corrupt = first.clone();
        corrupt[corrupt.length - 8] ^= 1;
        assertThrows(IOException.class, () -> drainStored(corrupt, settings));
        assertThrows(IOException.class, () -> drainStored(concatenate(first, new byte[]{1, 2, 3}), settings));
    }

    @Test
    void boundsGzipHeaderFilenameBeforeCompressionLibraryAllocatesIt() throws IOException {
        FileSettings settings = settings(Map.of("output.compression", "gzip", "output.header", "false"));
        byte[] data = write(settings, List.of(), List.of("content"));
        data[3] = 8;
        byte[] oversizedHeader = new byte[9_000];
        Arrays.fill(oversizedHeader, (byte) 'x');
        byte[] malformed = concatenate(concatenate(Arrays.copyOf(data, 10), oversizedHeader),
                Arrays.copyOfRange(data, 10, data.length));
        assertThrows(IOException.class, () -> drainStored(malformed, settings));
    }

    private static byte[] concatenate(byte[] first, byte[] second) {
        byte[] result = Arrays.copyOf(first, first.length + second.length);
        System.arraycopy(second, 0, result, first.length, second.length);
        return result;
    }

    private static void drainStored(byte[] stored, FileSettings settings) throws IOException {
        try (DelimitedReader reader = DelimitedFiles.reader(new ByteArrayInputStream(stored), settings)) {
            while (reader.read() != null) {
                // Validate the complete input and gzip trailer.
            }
        }
    }

    private static void read(String input, FileSettings settings) throws IOException {
        try (DelimitedReader reader = reader(input, settings)) {
            reader.read();
        }
    }

    private static DelimitedReader reader(String input, FileSettings settings) throws IOException {
        return DelimitedFiles.reader(new ByteArrayInputStream(input.getBytes(StandardCharsets.UTF_8)), settings);
    }

    private static byte[] write(FileSettings settings, List<String> header, List<String> row) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (DelimitedWriter writer = DelimitedFiles.writer(output, settings)) {
            writer.writeHeader(header);
            writer.write(row);
        }
        return output.toByteArray();
    }

    private static FileSettings settings(Map<String, String> values) {
        return FileSettings.from(values, "output");
    }
}
