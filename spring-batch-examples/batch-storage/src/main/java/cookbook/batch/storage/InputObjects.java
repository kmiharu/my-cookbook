package cookbook.batch.storage;

import java.util.Objects;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.HeadObjectResponse;

public final class InputObjects {
    private InputObjects() {}

    public static InputObjectVersion pin(S3Client client, String bucket, String key) {
        HeadObjectResponse head = client.headObject(request -> request.bucket(bucket).key(key));
        return new InputObjectVersion(bucket, key, head.versionId(), head.eTag(), head.contentLength());
    }

    public static ResponseInputStream<GetObjectResponse> open(S3Client client, InputObjectVersion input) {
        GetObjectRequest request = GetObjectRequest.builder().bucket(input.bucket()).key(input.key())
                .versionId(input.versionId()).ifMatch(input.eTag()).build();
        ResponseInputStream<GetObjectResponse> stream = client.getObject(request);
        GetObjectResponse response = stream.response();
        if (!Objects.equals(response.contentLength(), input.size())
                || input.versionId() != null && !input.versionId().equals(response.versionId())
                || input.eTag() != null && !input.eTag().equals(response.eTag())) {
            stream.abort();
            throw new IllegalStateException("Pinned S3 input identity changed for " + input.key());
        }
        return stream;
    }
}
