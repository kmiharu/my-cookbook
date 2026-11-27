package cookbook.batch.examples;

import java.time.OffsetDateTime;

public record CustomerConditions(OffsetDateTime fromDate, OffsetDateTime toDate, String status) {}
