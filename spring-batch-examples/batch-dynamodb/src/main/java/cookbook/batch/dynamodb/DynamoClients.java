package cookbook.batch.dynamodb;

import java.net.URI;
import java.time.Duration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.metrics.CoreMetric;
import software.amazon.awssdk.core.retry.RetryMode;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.metrics.MetricCollection;
import software.amazon.awssdk.metrics.MetricPublisher;
import java.util.concurrent.atomic.LongAdder;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;

public final class DynamoClients {
    private DynamoClients() {
    }

    public static DynamoDbClient open(String region, URI endpoint, boolean local) {
        return open(region, endpoint, local, new Metrics());
    }

    public static DynamoDbClient open(String region, URI endpoint, boolean local, Metrics metrics) {
        var builder = DynamoDbClient.builder().region(Region.of(region))
                .httpClientBuilder(UrlConnectionHttpClient.builder()
                        .connectionTimeout(Duration.ofSeconds(2)).socketTimeout(Duration.ofSeconds(4)))
                .overrideConfiguration(config -> config.addMetricPublisher(metrics).apiCallAttemptTimeout(Duration.ofSeconds(5))
                        .apiCallTimeout(Duration.ofSeconds(10))
                        .retryStrategy(RetryMode.STANDARD).retryStrategy(strategy -> strategy.maxAttempts(2)));
        if (endpoint != null) {
            if (!local || !java.util.Set.of("http", "https").contains(endpoint.getScheme())
                    || endpoint.getHost() == null || endpoint.getUserInfo() != null) {
                throw new IllegalArgumentException("DynamoDB endpoint override requires a local HTTP(S) endpoint");
            }
            builder.endpointOverride(endpoint).credentialsProvider(StaticCredentialsProvider.create(
                    AwsBasicCredentials.create("local", "local")));
        }
        return builder.build();
    }

    public static final class Metrics implements MetricPublisher {
        private final LongAdder calls = new LongAdder();
        private final LongAdder retries = new LongAdder();
        private final LongAdder callNanos = new LongAdder();

        @Override
        public void publish(MetricCollection metrics) {
            calls.increment();
            metrics.metricValues(CoreMetric.RETRY_COUNT).forEach(retries::add);
            metrics.metricValues(CoreMetric.API_CALL_DURATION).forEach(duration -> callNanos.add(duration.toNanos()));
        }

        @Override
        public void close() {
            // No state beyond counters.
        }

        @Override
        public String toString() {
            return "sdkCalls=" + calls.sum() + " sdkRetries=" + retries.sum() + " sdkCallNs=" + callNanos.sum();
        }
    }
}
