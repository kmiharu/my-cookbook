package cookbook.api;

import java.math.BigInteger;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

record ProductInput(String name, String category, Long priceMinor, String status) {
    private static final Set<String> FIELDS = Set.of("name", "category", "priceMinor", "status");
    private static final Pattern CATEGORY = Pattern.compile("[a-z0-9][a-z0-9-]{0,39}");
    private static final Pattern ID = Pattern.compile("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");

    static ProductInput full(Map<String, Object> body) {
        return parse(body, false);
    }

    static ProductInput partial(Map<String, Object> body) {
        return parse(body, true);
    }

    private static ProductInput parse(Map<String, Object> body, boolean partial) {
        if (body == null || body.isEmpty() || !FIELDS.containsAll(body.keySet())
                || (!partial && !body.keySet().containsAll(FIELDS))) {
            throw ApiProblem.invalid(partial ? "Supply at least one writable field" : "Supply all writable fields");
        }

        String name = null;
        if (body.containsKey("name")) {
            name = text(body.get("name"), "name").strip();
            int length = name.codePointCount(0, name.length());
            if (length < 1 || length > 120 || name.indexOf('\0') >= 0) {
                throw ApiProblem.invalid("name must contain between 1 and 120 characters and no NUL");
            }
        }
        String category = body.containsKey("category") ? category(text(body.get("category"), "category")) : null;
        Long priceMinor = body.containsKey("priceMinor") ? price(body.get("priceMinor")) : null;
        String status = null;
        if (body.containsKey("status")) {
            status = text(body.get("status"), "status");
            if (!Set.of("ACTIVE", "INACTIVE").contains(status)) {
                throw ApiProblem.invalid("status must be ACTIVE or INACTIVE");
            }
        }
        return new ProductInput(name, category, priceMinor, status);
    }

    static String category(String value) {
        if (!CATEGORY.matcher(value).matches()) {
            throw ApiProblem.invalid("category must match [a-z0-9][a-z0-9-]{0,39}");
        }
        return value;
    }

    static String id(String value) {
        if (!ID.matcher(value).matches()) {
            throw ApiProblem.invalid("id must be a lowercase UUID v4");
        }
        return value;
    }

    private static String text(Object value, String field) {
        if (value instanceof String result) {
            return result;
        }
        throw ApiProblem.invalid(field + " must be a string");
    }

    private static long price(Object value) {
        if (value instanceof BigInteger big && big.signum() >= 0 && big.bitLength() <= 30
                && big.longValue() <= 999_999_999) {
            return big.longValue();
        }
        if ((value instanceof Integer || value instanceof Long) && value instanceof Number number
                && number.longValue() >= 0 && number.longValue() <= 999_999_999) {
            return number.longValue();
        }
        throw ApiProblem.invalid("priceMinor must be an integer between 0 and 999999999");
    }
}
