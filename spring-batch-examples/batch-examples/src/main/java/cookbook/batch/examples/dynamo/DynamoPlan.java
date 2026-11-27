package cookbook.batch.examples.dynamo;

import cookbook.batch.dynamodb.DynamoCustomer;
import cookbook.batch.dynamodb.DynamoRepository;
import cookbook.batch.examples.RunContext;
import java.math.BigDecimal;
import java.util.Locale;
import java.util.Set;

record DynamoPlan(DynamoRepository.Read read, int batchSize, int workers, int rateLimit,
                  int retryAttempts, int retrySeconds, String targetPartition, String writeMode,
                  String operation, long expectedItems) {
    private static final String GENERATION = "generation:";

    static DynamoPlan from(RunContext context, DynamoSettings config) {
        var args = context.args();
        var job = context.job();
        String partition = args.value("dynamo.partition", config.partition());
        new DynamoCustomer.Key(partition, "probe");
        String mode = args.value("dynamo.readMode",
                job.equals("DynamoDbScanExport") ? "scan" : config.readMode());
        DynamoRepository.ReadMode readMode = DynamoRepository.ReadMode.valueOf(mode.toUpperCase(Locale.ROOT));
        if ((job.equals("DynamoDbQueryExport") && readMode != DynamoRepository.ReadMode.QUERY)
                || (job.equals("DynamoDbScanExport") && readMode != DynamoRepository.ReadMode.SCAN)) {
            throw new IllegalArgumentException("DynamoDB read mode does not match the job");
        }
        var status = args.value("dynamo.status", null);
        int pageLimit = args.integer("dynamo.pageLimit", config.pageLimit(), 1, 10_000);
        int batchSize = args.integer("dynamo.batchSize", config.batchSize(), 1, 25);
        int workers = args.integer("dynamo.workers", config.workers(), 1, 8);
        int rateLimit = args.integer("dynamo.rateLimit", config.rateLimit(), 0, 100_000);
        int retryAttempts = args.integer("dynamo.retryAttempts", config.retryAttempts(), 1, 10);
        int retrySeconds = args.integer("dynamo.retrySeconds", config.retrySeconds(), 1, 120);
        String writeMode = args.value("dynamo.writeMode", "insertOnly");
        String targetPartition = args.value("dynamo.targetPartition", null);
        String operation = args.value("dynamo.operation", "default");
        long expectedItems = Long.parseLong(args.value("dynamo.expectedItems", "-1"));
        if (expectedItems < -1) {
            throw new IllegalArgumentException("Invalid DynamoDB expectedItems");
        }
        if (!Set.of("insertOnly", "replace").contains(writeMode)
                || (!job.equals("DynamoDbImport") && !writeMode.equals("insertOnly"))) {
            throw new IllegalArgumentException("DynamoDB replace is explicit and is available for import only");
        }
        switch (job) {
            case "DynamoDbConditionalUpdate" -> requireOperation(operation, "default", "update", "add");
            case "PostgreSqlToDynamoDb" -> {
                requireOperation(operation, "default", "outbox");
                if (operation.equals("outbox") && (status == null || status.isBlank())) {
                    throw new IllegalArgumentException("dynamo.status required for outbox");
                }
            }
            default -> requireOperation(operation, "default");
        }
        if (writeMode.equals("replace")) {
            dedicated(partition);
        }
        if (targetPartition != null) {
            dedicated(targetPartition);
            if (partition.equals(targetPartition) || !job.equals("DynamoDbBenchmark")) {
                throw new IllegalArgumentException("Benchmark needs a distinct target generation");
            }
        }
        if (status != null) {
            new DynamoCustomer(new DynamoCustomer.Key(partition, "probe"), 0, status,
                    BigDecimal.ZERO, DynamoCustomer.Text.absent());
        }
        return new DynamoPlan(new DynamoRepository.Read(readMode, partition, args.bool("dynamo.gsi", false),
                status, args.bool("dynamo.consistentRead", false), pageLimit),
                batchSize, workers, rateLimit, retryAttempts, retrySeconds, targetPartition, writeMode,
                operation, expectedItems);
    }

    boolean deliversOutbox() {
        return operation.equals("outbox");
    }

    boolean replacesGeneration() {
        return writeMode.equals("replace");
    }

    private static void dedicated(String partition) {
        new DynamoCustomer.Key(partition, "probe");
        if (!partition.startsWith(GENERATION) || partition.equals(GENERATION)) {
            throw new IllegalArgumentException("BatchWrite requires a dedicated generation:<name> partition");
        }
    }

    static boolean dedicatedGeneration(String partition) {
        return partition.startsWith(GENERATION);
    }

    private static void requireOperation(String current, String... allowed) {
        if (!Set.of(allowed).contains(current)) {
            throw new IllegalArgumentException("Unsupported DynamoDB operation");
        }
    }
}
