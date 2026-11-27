package cookbook.batch.dynamodb;

import static cookbook.batch.dynamodb.DynamoCustomer.*;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.Delete;
import software.amazon.awssdk.services.dynamodb.model.Put;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItem;
import software.amazon.awssdk.services.dynamodb.model.Update;

/** Stable mutation semantics shared by CSV delivery, outbox delivery and retries. */
public record DynamoMutation(String operationId, Kind kind, DynamoCustomer.Key key,
                             long expectedVersion, DynamoCustomer customer, BigDecimal delta) {
    public enum Kind { INSERT_ONLY, REPLACE, UPDATE, STATUS, ADD, DELETE }

    public DynamoMutation {
        Objects.requireNonNull(operationId, "operationId");
        Objects.requireNonNull(kind, "kind");
        Objects.requireNonNull(key, "key");
        if (operationId.isBlank() || operationId.getBytes(StandardCharsets.UTF_8).length > 1024
                || expectedVersion < -1 || expectedVersion == Long.MAX_VALUE) {
            throw new IllegalArgumentException("Invalid operation ID or version");
        }
        switch (kind) {
            case INSERT_ONLY, REPLACE, UPDATE, STATUS -> {
                Objects.requireNonNull(customer, "customer");
                if (!key.equals(customer.key()) || (expectedVersion >= 0 && customer.version() != expectedVersion + 1)
                        || (kind == Kind.INSERT_ONLY && expectedVersion != -1)
                        || ((kind == Kind.UPDATE || kind == Kind.STATUS) && expectedVersion < 0)) {
                    throw new IllegalArgumentException("Mutation key or version does not match its payload");
                }
            }
            case ADD, DELETE -> {
                if (expectedVersion < 0 || customer != null) {
                    throw new IllegalArgumentException("Mutation requires the old version");
                }
            }
        }
        if (kind == Kind.ADD) {
            checkNumber(delta);
        } else if (delta != null) {
            throw new IllegalArgumentException("Only ADD accepts a delta");
        }
    }

    String payloadHash(String table) {
        try {
            var digest = MessageDigest.getInstance("SHA-256");
            hash(digest, table);
            hash(digest, kind.name());
            hash(digest, key.pk());
            hash(digest, key.sk());
            hash(digest, Long.toString(expectedVersion));
            if (customer != null) {
                hash(digest, Long.toString(customer.version()));
                hash(digest, customer.status());
                hash(digest, customer.balance().stripTrailingZeros().toString());
                hash(digest, Boolean.toString(customer.memo().present()));
                hash(digest, customer.memo().value());
            }
            if (delta != null) {
                hash(digest, delta.stripTrailingZeros().toString());
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static void hash(MessageDigest digest, String value) {
        if (value == null) {
            digest.update((byte) 0);
            return;
        }
        digest.update((byte) 1);
        var bytes = value.getBytes(StandardCharsets.UTF_8);
        digest.update(java.nio.ByteBuffer.allocate(Integer.BYTES).putInt(bytes.length).array());
        digest.update(bytes);
    }

    TransactWriteItem write(String table) {
        return switch (kind) {
            case INSERT_ONLY, REPLACE -> put(table);
            case UPDATE, STATUS, ADD -> update(table);
            case DELETE -> TransactWriteItem.builder().delete(Delete.builder()
                    .tableName(table).key(key.attributes()).conditionExpression("#version = :old")
                    .expressionAttributeNames(Map.of("#version", VERSION))
                    .expressionAttributeValues(Map.of(":old", number(expectedVersion))).build()).build();
        };
    }

    private TransactWriteItem put(String table) {
        var put = Put.builder().tableName(table).item(customer.attributes());
        if (expectedVersion == -1) {
            put.conditionExpression("attribute_not_exists(#key)")
                    .expressionAttributeNames(Map.of("#key", PK));
        } else {
            put.conditionExpression("#version = :old")
                    .expressionAttributeNames(Map.of("#version", VERSION))
                    .expressionAttributeValues(Map.of(":old", number(expectedVersion)));
        }
        return TransactWriteItem.builder().put(put.build()).build();
    }

    private TransactWriteItem update(String table) {
        var names = new LinkedHashMap<>(Map.of("#version", VERSION));
        var values = new LinkedHashMap<>(Map.of(":old", number(expectedVersion), ":next", number(expectedVersion + 1)));
        String expression;
        if (kind == Kind.ADD) {
            expression = "SET #version = :next ADD #balance :balance";
            names.put("#balance", BALANCE);
            values.put(":balance", number(delta));
        } else {
            var item = customer.attributes();
            names.putAll(Map.of("#status", STATUS, "#gsi_pk", GSI_PK, "#gsi_sk", GSI_SK));
            values.putAll(Map.of(":status", item.get(STATUS), ":gsi_pk", item.get(GSI_PK),
                    ":gsi_sk", item.get(GSI_SK)));
            expression = "SET #version = :next, #status = :status, #gsi_pk = :gsi_pk, #gsi_sk = :gsi_sk";
            if (kind == Kind.UPDATE) {
                names.put("#balance", BALANCE);
                values.put(":balance", item.get(BALANCE));
                expression += ", #balance = :balance";
                if (customer.memo().present()) {
                    names.put("#memo", MEMO);
                    values.put(":memo", item.get(MEMO));
                    expression += ", #memo = :memo";
                }
            }
        }
        return TransactWriteItem.builder().update(Update.builder().tableName(table)
                .key(key.attributes()).conditionExpression("#version = :old").updateExpression(expression)
                .expressionAttributeNames(names).expressionAttributeValues(values).build()).build();
    }
}
