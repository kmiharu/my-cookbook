package cookbook.batch.dynamodb;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

/** PK identifies the input generation. SK is a customer identifier within that generation. */
public record DynamoCustomer(
        Key key, long version, String status, BigDecimal balance, Text memo) {

    public static final String PK = "pk";
    public static final String SK = "sk";
    public static final String GSI_PK = "gsi_pk";
    public static final String GSI_SK = "gsi_sk";
    public static final String GSI = "by-status";
    public static final String VERSION = "version";
    public static final String STATUS = "status";
    public static final String BALANCE = "balance";
    public static final String MEMO = "memo";
    private static final int MAX_ITEM_BYTES = 400 * 1024;

    public DynamoCustomer {
        Objects.requireNonNull(key, "key");
        Objects.requireNonNull(memo, "memo");
        if (memo.value != null && (memo.value.length() > MAX_ITEM_BYTES
                || !StandardCharsets.UTF_8.newEncoder().canEncode(memo.value))) {
            throw new IllegalArgumentException("Invalid DynamoDB memo text");
        }
        if (version < 0) {
            throw new IllegalArgumentException("version must be nonnegative");
        }
        requireText(status, 64, "status");
        checkNumber(balance);
    }

    public record Key(String pk, String sk) {
        public Key {
            requireText(pk, 1024, "pk");
            requireText(sk, 1024, "sk");
            if (utf8(pk) + utf8(sk) + Integer.toString(pk.length()).length() + 1 > 1024) {
                throw new IllegalArgumentException("DynamoDB composite GSI sort key exceeds 1024 bytes");
            }
        }

        public Map<String, AttributeValue> attributes() {
            return Map.of(PK, text(pk), SK, text(sk));
        }
    }

    public record Text(boolean present, String value) {
        public Text {
            if (!present && value != null) {
                throw new IllegalArgumentException("Absent text cannot have a value");
            }
        }

        public static Text absent() {
            return new Text(false, null);
        }

        public static Text nullable(String value) {
            return new Text(true, value);
        }
    }

    public Map<String, AttributeValue> attributes() {
        var item = new LinkedHashMap<>(key.attributes());
        item.put(VERSION, number(version));
        item.put(STATUS, text(status));
        item.put(BALANCE, number(balance));
        item.put(GSI_PK, text(status));
        item.put(GSI_SK, text(gsiKey(key)));
        if (memo.present) {
            item.put(MEMO, memo.value == null
                    ? AttributeValue.builder().nul(true).build() : text(memo.value));
        }
        if (estimatedItemBytes(item) > MAX_ITEM_BYTES) {
            throw new IllegalArgumentException("DynamoDB item exceeds 400 KiB");
        }
        return Map.copyOf(item);
    }

    public static DynamoCustomer from(Map<String, AttributeValue> item) {
        // Unknown attributes could indicate a newer or incompatible source schema.
        if (!java.util.Set.of(PK, SK, VERSION, STATUS, BALANCE, GSI_PK, GSI_SK, MEMO)
                .containsAll(item.keySet())) {
            throw new IllegalArgumentException("Unsupported DynamoDB attribute");
        }
        var key = new Key(string(item, PK), string(item, SK));
        var status = string(item, STATUS);
        if (!status.equals(string(item, GSI_PK)) || !gsiKey(key).equals(string(item, GSI_SK))) {
            throw new IllegalArgumentException("DynamoDB GSI values do not match the business key");
        }
        var memo = item.get(MEMO);
        Text value;
        if (memo == null) {
            value = Text.absent();
        } else if (memo.type() == AttributeValue.Type.NUL && Boolean.TRUE.equals(memo.nul())) {
            value = Text.nullable(null);
        } else {
            value = Text.nullable(string(item, MEMO));
        }
        return new DynamoCustomer(key, new BigDecimal(numeric(item, VERSION)).longValueExact(),
                status, new BigDecimal(numeric(item, BALANCE)), value);
    }

    static int estimatedItemBytes(Map<String, AttributeValue> item) {
        int bytes = 0;
        for (var entry : item.entrySet()) {
            var attribute = entry.getValue();
            int size = switch (attribute.type()) {
                case S -> utf8(attribute.s());
                case N -> attribute.n().length();
                case NUL -> 1;
                default -> throw new IllegalArgumentException("Unsupported DynamoDB attribute type");
            };
            bytes = Math.addExact(bytes, 8 + utf8(entry.getKey()) + size);
        }
        return bytes;
    }

    static AttributeValue text(String value) {
        return AttributeValue.fromS(value);
    }

    static AttributeValue number(long value) {
        return AttributeValue.fromN(Long.toString(value));
    }

    static AttributeValue number(BigDecimal value) {
        checkNumber(value);
        return AttributeValue.fromN(value.stripTrailingZeros().toString());
    }

    static String gsiKey(Key key) {
        return key.pk().length() + ":" + key.pk() + key.sk();
    }

    static String string(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        if (value == null || value.type() != AttributeValue.Type.S) {
            throw new IllegalArgumentException("String attribute required: " + name);
        }
        return value.s();
    }

    private static String numeric(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        if (value == null || value.type() != AttributeValue.Type.N) {
            throw new IllegalArgumentException("Number attribute required: " + name);
        }
        return value.n();
    }

    private static void requireText(String value, int maximumBytes, String name) {
        if (value == null || value.isEmpty() || utf8(value) > maximumBytes) {
            throw new IllegalArgumentException("Invalid DynamoDB " + name);
        }
        if (!StandardCharsets.UTF_8.newEncoder().canEncode(value)) {
            throw new IllegalArgumentException("Invalid Unicode in " + name);
        }
    }

    static void checkNumber(BigDecimal value) {
        Objects.requireNonNull(value, "number");
        var normalized = value.stripTrailingZeros();
        long exponent = (long) normalized.precision() - normalized.scale() - 1L;
        if (normalized.precision() > 38 || (value.signum() != 0 && (exponent < -130 || exponent > 125))) {
            throw new IllegalArgumentException("DynamoDB number out of range");
        }
    }

    private static int utf8(String value) {
        return value.getBytes(StandardCharsets.UTF_8).length;
    }
}
