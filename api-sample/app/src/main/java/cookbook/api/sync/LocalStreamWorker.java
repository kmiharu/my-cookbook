package cookbook.api.sync;

import cookbook.api.db.PostgresRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.services.dynamodb.model.ExpiredIteratorException;
import software.amazon.awssdk.services.dynamodb.model.GetRecordsResponse;
import software.amazon.awssdk.services.dynamodb.model.Shard;
import software.amazon.awssdk.services.dynamodb.model.ShardIteratorType;
import software.amazon.awssdk.services.dynamodb.streams.DynamoDbStreamsClient;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class LocalStreamWorker {
    private static final Logger LOG = LoggerFactory.getLogger(LocalStreamWorker.class);
    private static final long POLL_MILLIS = 250;
    private final DynamoDbStreamsClient streams;
    private final PostgresRepository repository;
    private final SyncState state;
    private final Map<String, String> iterators = new HashMap<>();

    LocalStreamWorker(DynamoDbStreamsClient streams, PostgresRepository repository, SyncState state) {
        this.streams = streams;
        this.repository = repository;
        this.state = state;
    }

    void run(String arn) throws IOException, InterruptedException {
        try (var workerLock = state.lockWorker()) {
            LOG.info("operation=stream_start streamArn={}", arn);
            while (!Thread.currentThread().isInterrupted()) {
                var shards = shards(arn);
                Set<String> liveShards = new HashSet<>();
                shards.forEach(shard -> liveShards.add(shard.shardId()));
                for (Shard shard : shards) {
                    String parent = shard.parentShardId();
                    if (parent != null && liveShards.contains(parent) && !state.checkpoint(arn, parent).closed()) {
                        continue;
                    }
                    poll(arn, shard.shardId());
                }
                Thread.sleep(POLL_MILLIS);
            }
        }
    }

    private List<Shard> shards(String arn) {
        var shards = new ArrayList<Shard>();
        String after = null;
        do {
            String cursor = after;
            var description = streams.describeStream(request -> request.streamArn(arn).exclusiveStartShardId(cursor))
                .streamDescription();
            shards.addAll(description.shards());
            after = description.lastEvaluatedShardId();
        } while (after != null);
        return shards;
    }

    private void poll(String arn, String shard) throws IOException {
        var checkpoint = state.checkpoint(arn, shard);
        if (checkpoint.closed()) {
            return;
        }

        String iterator = iterators.computeIfAbsent(shard, ignored -> iterator(arn, shard, checkpoint.sequence()));
        GetRecordsResponse batch;
        try {
            batch = streams.getRecords(request -> request.shardIterator(iterator).limit(100));
        } catch (ExpiredIteratorException expired) {
            iterators.remove(shard);
            return;
        }
        String lastSequence = checkpoint.sequence();
        for (var record : batch.records()) {
            var stream = record.dynamodb();
            String sequence = stream.sequenceNumber();
            String operation = record.eventNameAsString();
            var image = "REMOVE".equals(operation) ? stream.oldImage() : stream.newImage();
            try {
                ProductChanges.apply(repository, operation, image);
            } catch (RuntimeException failure) {
                state.saveFailure(arn, shard, sequence, operation, image);
                LOG.warn("operation=stream_project shard={} sequence={} outcome=failed", shard, sequence, failure);
                iterators.remove(shard);
                return;
            }

            lastSequence = sequence;
            state.saveCheckpoint(arn, shard, new SyncState.Checkpoint(sequence, false));
        }

        if (batch.nextShardIterator() != null) {
            iterators.put(shard, batch.nextShardIterator());
        } else {
            state.saveCheckpoint(arn, shard, new SyncState.Checkpoint(lastSequence, true));
            iterators.remove(shard);
        }
    }

    private String iterator(String arn, String shard, String sequence) {
        return streams.getShardIterator(request -> request.streamArn(arn).shardId(shard)
            .shardIteratorType(sequence == null ? ShardIteratorType.TRIM_HORIZON : ShardIteratorType.AFTER_SEQUENCE_NUMBER)
            .sequenceNumber(sequence)).shardIterator();
    }
}
