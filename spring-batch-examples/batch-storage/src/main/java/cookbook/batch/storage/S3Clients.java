package cookbook.batch.storage;

import java.net.URI;
import java.time.Duration;
import java.util.Objects;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.checksums.RequestChecksumCalculation;
import software.amazon.awssdk.core.checksums.ResponseChecksumValidation;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3ClientBuilder;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.sts.StsClient;
import software.amazon.awssdk.services.sts.auth.StsAssumeRoleCredentialsProvider;
import software.amazon.awssdk.services.sts.model.AssumeRoleRequest;

public final class S3Clients implements AutoCloseable {
    private static final ClientOverrideConfiguration TIMEOUTS = ClientOverrideConfiguration.builder()
            .apiCallAttemptTimeout(Duration.ofSeconds(12))
            .apiCallTimeout(Duration.ofSeconds(30))
            .build();

    private final S3Client client;
    private final StsClient sts;
    private final StsAssumeRoleCredentialsProvider assumedCredentials;

    private S3Clients(S3Client client, StsClient sts, StsAssumeRoleCredentialsProvider assumedCredentials) {
        this.client = client;
        this.sts = sts;
        this.assumedCredentials = assumedCredentials;
    }

    public static S3Clients local(String region, URI endpoint, String accessKey, String secretKey) {
        Objects.requireNonNull(endpoint, "local S3 endpoint");
        S3Client client = builder(region)
                .endpointOverride(endpoint)
                .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create(accessKey, secretKey)))
                .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build())
                .build();
        return new S3Clients(client, null, null);
    }

    public static S3Clients aws(String region, String roleArn, String externalId) {
        if (roleArn == null || roleArn.isBlank()) {
            if (externalId != null && !externalId.isBlank()) {
                throw new IllegalArgumentException("External ID requires an AssumeRole ARN");
            }
            return new S3Clients(builder(region).build(), null, null);
        }
        StsClient sts = StsClient.builder().region(Region.of(region))
                .httpClientBuilder(httpClient()).overrideConfiguration(TIMEOUTS).build();
        AssumeRoleRequest request = AssumeRoleRequest.builder()
                .roleArn(roleArn).roleSessionName("cookbook-batch-s3").externalId(externalId).build();
        StsAssumeRoleCredentialsProvider provider = StsAssumeRoleCredentialsProvider.builder()
                .stsClient(sts).refreshRequest(request).build();
        try {
            return new S3Clients(builder(region).credentialsProvider(provider).build(), sts, provider);
        } catch (RuntimeException e) {
            provider.close();
            sts.close();
            throw e;
        }
    }

    public S3Client client() {
        return client;
    }

    private static S3ClientBuilder builder(String region) {
        // The artifact ledger verifies SHA-256 over the stored bytes. Use ordinary ETag-only
        // multipart completion, including on S3-compatible endpoints.
        return S3Client.builder().region(Region.of(region))
                .requestChecksumCalculation(RequestChecksumCalculation.WHEN_REQUIRED)
                .responseChecksumValidation(ResponseChecksumValidation.WHEN_REQUIRED)
                .httpClientBuilder(httpClient()).overrideConfiguration(TIMEOUTS);
    }

    private static UrlConnectionHttpClient.Builder httpClient() {
        return UrlConnectionHttpClient.builder().connectionTimeout(Duration.ofSeconds(4))
                .socketTimeout(Duration.ofSeconds(10));
    }

    @Override
    public void close() {
        try {
            client.close();
        } finally {
            if (assumedCredentials != null) {
                try {
                    assumedCredentials.close();
                } finally {
                    sts.close();
                }
            }
        }
    }
}
