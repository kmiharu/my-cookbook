package cookbook.batch.examples;

public record InputCustomer(String job, String run, int fileIndex, long ordinal, long customerId,
                            String name, String email, String status, Long expectedVersion, String error) {}
