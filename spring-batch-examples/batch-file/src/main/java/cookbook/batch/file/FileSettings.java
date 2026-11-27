package cookbook.batch.file;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.text.DecimalFormat;
import java.text.DecimalFormatSymbols;
import java.text.ParsePosition;
import java.time.ZoneId;
import java.time.chrono.IsoEra;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.time.format.ResolverStyle;
import java.time.temporal.ChronoField;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public record FileSettings(
        Format format, Compression compression, Charset charset, boolean header, boolean bom,
        LineEnding lineEnding, char delimiter, char quote, Escape escape, String nullValue,
        List<String> columns, List<String> columnNames, String dateFormat, ZoneId timeZone, String numberFormat, int gzipLevel,
        int maxColumns, int maxColumnChars, int maxRecordChars) {

    public enum Format { CSV, TSV }
    public enum Compression { NONE, GZIP }
    public enum Escape { DOUBLE_QUOTE, BACKSLASH }
    public enum LineEnding {
        LF("\n"), CRLF("\r\n");

        private final String characters;

        LineEnding(String characters) {
            this.characters = characters;
        }

        public String characters() {
            return characters;
        }
    }

    public FileSettings {
        if (bom && !StandardCharsets.UTF_8.equals(charset)) {
            throw new IllegalArgumentException("BOM is supported only with UTF-8");
        }
        if (delimiter == quote || (delimiter != '\t' && Character.isISOControl(delimiter))
                || Character.isISOControl(quote) || Character.isSurrogate(delimiter)
                || Character.isSurrogate(quote)
                || escape == Escape.BACKSLASH && (delimiter == '\\' || quote == '\\')) {
            throw new IllegalArgumentException("delimiter, quote, and escape conflict");
        }
        if (nullValue.indexOf(delimiter) >= 0 || nullValue.indexOf(quote) >= 0
                || nullValue.indexOf('\r') >= 0 || nullValue.indexOf('\n') >= 0
                || nullValue.startsWith("\uFEFF")) {
            throw new IllegalArgumentException("NULL token must be writable as an unquoted field");
        }
        if (!roundTrips(charset, Character.toString(delimiter)) || !roundTrips(charset, Character.toString(quote))
                || !roundTrips(charset, nullValue)) {
            throw new IllegalArgumentException("delimiter, quote, and NULL token must be representable in the charset");
        }
        if (maxRecordChars < 1 || maxColumnChars < 1 || maxColumns < 1
                || nullValue.length() > maxColumnChars || nullValue.length() > maxRecordChars) {
            throw new IllegalArgumentException("invalid delimited record limits");
        }
        if (gzipLevel < 0 || gzipLevel > 9) {
            throw new IllegalArgumentException("gzipLevel must be between 0 and 9");
        }
        columns = List.copyOf(columns);
        if (columns.size() > maxColumns || columns.stream().anyMatch(String::isBlank)
                || columns.stream().distinct().count() != columns.size()) {
            throw new IllegalArgumentException("columns must contain distinct, non-blank names");
        }
        if (columns.stream().anyMatch(column -> !roundTrips(charset, column))) {
            throw new IllegalArgumentException("columns must be representable in the charset");
        }
        columnNames = List.copyOf(columnNames);
        if (!columnNames.isEmpty() && (!header || columnNames.size() > maxColumns
                || !columns.isEmpty() && columns.size() != columnNames.size()
                || columnNames.stream().anyMatch(name -> name.isBlank() || name.length() > maxColumnChars
                    || name.indexOf('\r') >= 0 || name.indexOf('\n') >= 0)
                || columnNames.stream().distinct().count() != columnNames.size())) {
            throw new IllegalArgumentException("columnNames requires a header with one distinct name per column");
        }
        DateTimeFormatter.ofPattern(dateFormat, Locale.ROOT);
        if (!numberFormat.equals("plain")) {
            new DecimalFormat(numberFormat, DecimalFormatSymbols.getInstance(Locale.ROOT));
        }
    }

    public static FileSettings defaults() {
        return from(Map.of(), "output");
    }

    public static FileSettings from(Map<String, String> values, String prefix) {
        String key = prefix.endsWith(".") ? prefix : prefix + ".";
        Format format = enumValue(Format.class, values.getOrDefault(key + "format", "csv"), key + "format");
        String list = values.getOrDefault(key + "columns", "");
        List<String> columns = list.isEmpty() ? List.of() : Arrays.asList(list.split(",", -1));
        String headerNames = values.getOrDefault(key + "columnNames", "");
        List<String> names = headerNames.isEmpty() ? List.of() : Arrays.asList(headerNames.split(",", -1));
        return new FileSettings(
                format,
                enumValue(Compression.class, values.getOrDefault(key + "compression", "none"), key + "compression"),
                charset(values.getOrDefault(key + "charset", "UTF-8")),
                bool(values, key + "header", true),
                bool(values, key + "bom", false),
                enumValue(LineEnding.class, values.getOrDefault(key + "lineEnding", "lf"), key + "lineEnding"),
                character(values.getOrDefault(key + "delimiter", format == Format.TSV ? "\t" : ","), key + "delimiter"),
                character(values.getOrDefault(key + "quote", "\""), key + "quote"),
                escape(values.getOrDefault(key + "escape", "double-quote"), key + "escape"),
                values.getOrDefault(key + "nullValue", ""),
                columns,
                names,
                values.getOrDefault(key + "dateFormat", "uuuu-MM-dd"),
                zone(values.getOrDefault(key + "timeZone", "UTC"), key + "timeZone"),
                values.getOrDefault(key + "numberFormat", "plain"),
                integer(values, key + "gzipLevel", 6, 0, 9),
                integer(values, key + "maxColumns", 128, 1, 4096),
                integer(values, key + "maxColumnChars", 8192, 1, 8_388_608),
                integer(values, key + "maxRecordChars", 16_384, 1, 8_388_608));
    }

    public List<String> columnsOr(List<String> defaults) {
        return columns.isEmpty() ? List.copyOf(defaults) : columns;
    }

    public List<String> headerFor(List<String> columnOrder) {
        if (columnNames.isEmpty()) {
            return columnOrder;
        }
        if (columnNames.size() != columnOrder.size()) {
            throw new IllegalArgumentException("columnNames does not match the number of columns");
        }
        return columnNames;
    }

    public DateTimeFormatter dateFormatter() {
        return new DateTimeFormatterBuilder().appendPattern(dateFormat)
                .parseDefaulting(ChronoField.ERA, IsoEra.CE.getValue())
                .toFormatter(Locale.ROOT)
                .withResolverStyle(ResolverStyle.STRICT)
                .withZone(timeZone);
    }

    public String formatNumber(BigDecimal number) {
        return numberFormat.equals("plain") ? number.toPlainString() : decimalFormat().format(number);
    }

    public BigDecimal parseNumber(String value) {
        if (numberFormat.equals("plain")) {
            return new BigDecimal(value);
        }
        ParsePosition position = new ParsePosition(0);
        Number number = decimalFormat().parse(value, position);
        if (!(number instanceof BigDecimal exact) || position.getIndex() != value.length()) {
            throw new NumberFormatException("invalid decimal field");
        }
        return exact;
    }

    private DecimalFormat decimalFormat() {
        DecimalFormat formatter = new DecimalFormat(numberFormat, DecimalFormatSymbols.getInstance(Locale.ROOT));
        formatter.setParseBigDecimal(true);
        formatter.setRoundingMode(RoundingMode.UNNECESSARY);
        return formatter;
    }

    static boolean roundTrips(Charset encoding, String value) {
        return value.equals(new String(value.getBytes(encoding), encoding));
    }

    private static Charset charset(String value) {
        return switch (value.toLowerCase(Locale.ROOT)) {
            case "utf-8", "utf8" -> StandardCharsets.UTF_8;
            case "windows-31j", "ms932", "cp932" -> Charset.forName("windows-31j");
            default -> throw new IllegalArgumentException("charset must be UTF-8 or Windows-31J");
        };
    }

    private static ZoneId zone(String value, String name) {
        try {
            return ZoneId.of(value);
        } catch (RuntimeException invalid) {
            throw new IllegalArgumentException(name + " must be a valid time zone");
        }
    }

    private static Escape escape(String value, String name) {
        return switch (value) {
            case "\"", "double" -> Escape.DOUBLE_QUOTE;
            case "\\" -> Escape.BACKSLASH;
            default -> enumValue(Escape.class, value, name);
        };
    }

    private static char character(String value, String name) {
        if (value.equals("\\t") || value.equalsIgnoreCase("tab")) {
            return '\t';
        }
        if (value.length() != 1) {
            throw new IllegalArgumentException(name + " must be one character");
        }
        return value.charAt(0);
    }

    private static boolean bool(Map<String, String> values, String key, boolean fallback) {
        return switch (values.getOrDefault(key, Boolean.toString(fallback)).toLowerCase(Locale.ROOT)) {
            case "true" -> true;
            case "false" -> false;
            default -> throw new IllegalArgumentException(key + " must be true or false");
        };
    }

    private static int integer(Map<String, String> values, String key, int fallback, int minimum, int maximum) {
        int number;
        try {
            number = Integer.parseInt(values.getOrDefault(key, Integer.toString(fallback)));
        } catch (NumberFormatException invalid) {
            throw new IllegalArgumentException(key + " must be an integer");
        }
        if (number < minimum || number > maximum) {
            throw new IllegalArgumentException(key + " must be between " + minimum + " and " + maximum);
        }
        return number;
    }

    private static <T extends Enum<T>> T enumValue(Class<T> type, String value, String key) {
        try {
            return Enum.valueOf(type, value.toUpperCase(Locale.ROOT).replace('-', '_'));
        } catch (IllegalArgumentException invalid) {
            throw new IllegalArgumentException("unsupported " + key);
        }
    }
}
