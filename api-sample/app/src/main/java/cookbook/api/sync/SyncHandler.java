package cookbook.api.sync;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.DynamodbEvent;
import com.amazonaws.services.lambda.runtime.events.StreamsEventResponse;
import cookbook.api.Settings;
import cookbook.api.db.PostgresRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

public final class SyncHandler implements RequestHandler<DynamodbEvent, StreamsEventResponse> {
    private static final Logger LOG = LoggerFactory.getLogger(SyncHandler.class);
    private final PostgresRepository repository;

    public SyncHandler() {
        this(createRepository());
    }

    SyncHandler(PostgresRepository repository) {
        this.repository = repository;
    }

    private static PostgresRepository createRepository() {
        Settings settings = Settings.fromEnvironment();
        if (!"hybrid".equals(settings.mode())) {
            throw new IllegalArgumentException("The sync Lambda requires DATABASE_TYPE=hybrid");
        }
        return new PostgresRepository(settings);
    }

    @Override
    public StreamsEventResponse handleRequest(DynamodbEvent event, Context context) {
        var failures = new ArrayList<StreamsEventResponse.BatchItemFailure>();
        for (var record : event.getRecords()) {
            var stream = record.getDynamodb();
            if (stream == null || stream.getSequenceNumber() == null || stream.getSequenceNumber().isBlank()) {
                // A malformed record cannot be safely acknowledged through partial failure reporting.
                throw new IllegalArgumentException("Stream record has no sequence number");
            }
            String sequence = stream.getSequenceNumber();
            try {
                String operation = record.getEventName();
                var image = "REMOVE".equals(operation) ? stream.getOldImage() : stream.getNewImage();
                ProductChanges.apply(repository, operation, toSdkImage(image));
            } catch (RuntimeException failure) {
                LOG.warn("operation=stream_project sequence={} outcome=failed", sequence, failure);
                failures.add(new StreamsEventResponse.BatchItemFailure(sequence));
            }
        }
        return new StreamsEventResponse(failures);
    }

    private static Map<String, AttributeValue> toSdkImage(
        Map<String, com.amazonaws.services.lambda.runtime.events.models.dynamodb.AttributeValue> image) {
        var converted = new HashMap<String, AttributeValue>();
        if (image != null) {
            image.forEach((name, attribute) -> converted.put(name, AttributeValue.builder()
                .s(attribute.getS())
                .n(attribute.getN())
                .bool(attribute.getBOOL())
                .build()));
        }
        return converted;
    }
}
