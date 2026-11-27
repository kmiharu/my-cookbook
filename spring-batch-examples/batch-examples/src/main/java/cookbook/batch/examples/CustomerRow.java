package cookbook.batch.examples;

import java.time.OffsetDateTime;

public record CustomerRow(long customerId, long memberId, String name, String email,
                          String status, OffsetDateTime updatedAt, long version, String tier) {}
