package cookbook.batch.file;

import java.io.IOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** Writes one logical record without allocating a serialized copy of that record. */
public final class DelimitedWriter implements AutoCloseable {
    private final Writer output;
    private final FileSettings settings;

    DelimitedWriter(Writer output, FileSettings settings) {
        this.output = output;
        this.settings = settings;
    }

    public void write(List<String> cells) throws IOException {
        validateLength(cells);
        boolean first = true;
        for (String cell : cells) {
            if (!first) {
                output.write(settings.delimiter());
            }
            first = false;
            if (cell == null) {
                output.write(settings.nullValue());
            } else if (requiresQuote(cell)) {
                writeQuoted(cell);
            } else {
                output.write(cell);
            }
        }
        output.write(settings.lineEnding().characters());
    }

    public void writeHeader(List<String> columns) throws IOException {
        if (settings.header()) {
            write(settings.headerFor(columns));
        }
    }

    private void validateLength(List<String> cells) throws IOException {
        if (cells.isEmpty() || cells.size() > settings.maxColumns()) {
            throw new IOException("invalid output column count");
        }
        long recordChars = cells.size() - 1L;
        for (String cell : cells) {
            if (cell == null) {
                recordChars += settings.nullValue().length();
            } else {
                if (cell.length() > settings.maxColumnChars()) {
                    throw new IOException("maximum output column length exceeded");
                }
                if (!settings.charset().equals(StandardCharsets.UTF_8)
                        && !FileSettings.roundTrips(settings.charset(), cell)) {
                    throw new IOException("output column cannot round trip through the configured charset");
                }
                recordChars += cell.length();
                if (requiresQuote(cell)) {
                    recordChars += 2;
                    for (int i = 0; i < cell.length(); i++) {
                        if (isEscaped(cell.charAt(i))) {
                            recordChars++;
                        }
                    }
                }
            }
            if (recordChars > settings.maxRecordChars()) {
                throw new IOException("maximum output logical record length exceeded");
            }
        }
    }

    private boolean requiresQuote(String cell) {
        return cell.isEmpty() || cell.equals(settings.nullValue()) || cell.charAt(0) == '\uFEFF'
                || cell.indexOf(settings.quote()) >= 0 || cell.indexOf(settings.delimiter()) >= 0
                || cell.indexOf('\r') >= 0 || cell.indexOf('\n') >= 0;
    }

    private void writeQuoted(String cell) throws IOException {
        output.write(settings.quote());
        for (int i = 0; i < cell.length(); i++) {
            char character = cell.charAt(i);
            if (isEscaped(character)) {
                output.write(settings.escape() == FileSettings.Escape.BACKSLASH ? '\\' : settings.quote());
            }
            output.write(character);
        }
        output.write(settings.quote());
    }

    private boolean isEscaped(char character) {
        return character == settings.quote()
                || (character == '\\' && settings.escape() == FileSettings.Escape.BACKSLASH);
    }

    @Override
    public void close() throws IOException {
        output.close();
    }
}
