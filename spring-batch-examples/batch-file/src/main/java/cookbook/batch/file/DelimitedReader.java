package cookbook.batch.file;

import java.io.IOException;
import java.io.Reader;
import java.util.ArrayList;
import java.util.List;

/** A one-record-at-a-time CSV parser, also used with a tab delimiter. */
public final class DelimitedReader implements AutoCloseable {
    private enum State { START, UNQUOTED, QUOTED, AFTER_QUOTE }

    private final Reader input;
    private final FileSettings settings;
    private long records;

    DelimitedReader(Reader input, FileSettings settings) {
        this.input = input;
        this.settings = settings;
    }

    public List<String> read() throws IOException {
        int character = input.read();
        if (character < 0) {
            return null;
        }
        List<String> cells = new ArrayList<>();
        StringBuilder field = new StringBuilder();
        State state = State.START;
        boolean quoted = false;
        int recordChars = 0;
        while (true) {
            if (state != State.QUOTED && (character < 0 || character == '\r' || character == '\n')) {
                consumeRecordEnding(character);
                addCell(cells, field, quoted);
                records++;
                return cells;
            }
            if (character < 0) {
                throw malformed("unterminated quoted field");
            }
            checkRecordLength(++recordChars);
            if (state != State.QUOTED && character == settings.delimiter()) {
                addCell(cells, field, quoted);
                field.setLength(0);
                state = State.START;
                quoted = false;
            } else {
                switch (state) {
                    case START -> {
                        if (character == settings.quote()) {
                            state = State.QUOTED;
                            quoted = true;
                        } else {
                            state = State.UNQUOTED;
                            append(field, character);
                        }
                    }
                    case UNQUOTED -> {
                        if (character == settings.quote()) {
                            throw malformed("quote in an unquoted field");
                        }
                        append(field, character);
                    }
                    case QUOTED -> {
                        if (character == '\\' && settings.escape() == FileSettings.Escape.BACKSLASH) {
                            int escaped = input.read();
                            if (escaped != '\\' && escaped != settings.quote()) {
                                throw malformed("invalid quoted escape");
                            }
                            checkRecordLength(++recordChars);
                            append(field, escaped);
                        } else if (character == settings.quote()) {
                            state = State.AFTER_QUOTE;
                        } else {
                            append(field, character);
                        }
                    }
                    case AFTER_QUOTE -> {
                        if (character != settings.quote() || settings.escape() != FileSettings.Escape.DOUBLE_QUOTE) {
                            throw malformed("unexpected character after closing quote");
                        }
                        append(field, character);
                        state = State.QUOTED;
                    }
                }
            }
            character = input.read();
        }
    }

    public void requireHeader(List<String> columns) throws IOException {
        if (settings.header() && !settings.headerFor(columns).equals(read())) {
            throw new IOException("file header does not match the configured columns");
        }
    }

    public long recordsRead() {
        return records;
    }

    private void consumeRecordEnding(int character) throws IOException {
        if (character < 0) {
            return;
        }
        boolean valid = switch (settings.lineEnding()) {
            case LF -> character == '\n';
            case CRLF -> character == '\r' && input.read() == '\n';
        };
        if (!valid) {
            throw malformed("unexpected record line ending");
        }
    }

    private void append(StringBuilder field, int character) throws IOException {
        if (field.length() == settings.maxColumnChars()) {
            throw malformed("maximum column length exceeded");
        }
        field.append((char) character);
    }

    private void addCell(List<String> cells, StringBuilder field, boolean quoted) throws IOException {
        if (cells.size() == settings.maxColumns()) {
            throw malformed("maximum column count exceeded");
        }
        String value = field.toString();
        cells.add(!quoted && settings.nullValue().equals(value) ? null : value);
    }

    private void checkRecordLength(int length) throws IOException {
        if (length > settings.maxRecordChars()) {
            throw malformed("maximum logical record length exceeded");
        }
    }

    private IOException malformed(String reason) {
        return new IOException("logical record " + (records + 1) + " " + reason);
    }

    @Override
    public void close() throws IOException {
        input.close();
    }
}
