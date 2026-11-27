package cookbook.batch.dynamodb;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

/** Checkpoint-safe representation of LastEvaluatedKey, with types preserved. */
public final class PageKey {
    private static final Base64.Encoder ENCODER = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DECODER = Base64.getUrlDecoder();

    private PageKey() {
    }

    public static String encode(Map<String, AttributeValue> attributes) {
        return attributes.entrySet().stream().sorted(Map.Entry.comparingByKey())
                .map(entry -> encodeText(entry.getKey()) + ":" + encodeValue(entry.getValue()))
                .collect(java.util.stream.Collectors.joining(","));
    }

    public static Map<String, AttributeValue> decode(String checkpoint) {
        if (checkpoint == null || checkpoint.isEmpty()) {
            return Map.of();
        }
        var key = new LinkedHashMap<String, AttributeValue>();
        for (var item : checkpoint.split(",")) {
            var parts = item.split(":", -1);
            if (parts.length != 3) {
                throw new IllegalArgumentException("Invalid DynamoDB page checkpoint");
            }
            var value = switch (parts[1]) {
                case "S" -> AttributeValue.fromS(decodeText(parts[2]));
                case "N" -> AttributeValue.fromN(decodeText(parts[2]));
                case "B" -> AttributeValue.fromB(SdkBytes.fromByteArray(DECODER.decode(parts[2])));
                default -> throw new IllegalArgumentException("Unsupported DynamoDB page key type");
            };
            if (key.putIfAbsent(decodeText(parts[0]), value) != null) {
                throw new IllegalArgumentException("Duplicate key attribute in DynamoDB checkpoint");
            }
        }
        return Map.copyOf(key);
    }

    private static String encodeValue(AttributeValue value) {
        return switch (value.type()) {
            case S -> "S:" + encodeText(value.s());
            case N -> "N:" + encodeText(value.n());
            case B -> "B:" + ENCODER.encodeToString(value.b().asByteArray());
            default -> throw new IllegalArgumentException("Unsupported DynamoDB page key type");
        };
    }

    private static String encodeText(String value) {
        return ENCODER.encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private static String decodeText(String value) {
        return new String(DECODER.decode(value), StandardCharsets.UTF_8);
    }
}
