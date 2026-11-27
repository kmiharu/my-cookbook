package cookbook.batch.storage;

public record MultipartLimits(int partSize, int transferParallelism, int buffers, int maxParts) {
    public static final int S3_MAX_PARTS = 10_000;
    public static final int MIB = 1024 * 1024;

    public MultipartLimits(int partSize, int transferParallelism, int buffers) {
        this(partSize, transferParallelism, buffers, S3_MAX_PARTS);
    }

    public MultipartLimits {
        if (partSize < 5 * MIB || partSize > 64 * MIB) {
            throw new IllegalArgumentException("partSize must be 5–64 MiB");
        }
        if (transferParallelism < 1 || buffers < transferParallelism || buffers > 64) {
            throw new IllegalArgumentException("Require 1 <= transferParallelism <= buffers <= 64");
        }
        if (maxParts < 1 || maxParts > S3_MAX_PARTS) {
            throw new IllegalArgumentException("Invalid S3 part count");
        }
    }

    public long maxObjectBytes() {
        return (long) partSize * maxParts;
    }
}
