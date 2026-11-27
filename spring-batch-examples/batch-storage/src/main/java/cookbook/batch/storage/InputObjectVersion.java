package cookbook.batch.storage;

public record InputObjectVersion(String bucket, String key, String versionId, String eTag, long size) {
    public InputObjectVersion {
        if ("null".equals(versionId) || versionId != null && versionId.isBlank()) {
            versionId = null;
        }
        if (bucket == null || bucket.isBlank() || key == null || key.isEmpty()
                || versionId == null && (eTag == null || eTag.isBlank()) || size < 0) {
            throw new IllegalArgumentException("S3 input requires bucket, key, size and version or ETag");
        }
    }
}
