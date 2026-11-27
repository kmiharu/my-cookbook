package cookbook.api;

import io.micronaut.serde.annotation.Serdeable;
import java.time.Instant;

@Serdeable
public record Product(
        String id, String name, String category, long priceMinor, String status, long version,
        Instant createdAt, Instant updatedAt, boolean deleted
) {}
