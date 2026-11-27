package cookbook.api.sync;

import cookbook.api.Product;
import cookbook.api.Settings;
import cookbook.api.db.DynamoSupport;
import cookbook.api.db.PostgresRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.StreamViewType;

import java.io.IOException;
import java.nio.file.Path;
import java.util.function.Consumer;

public final class SyncMain {
    private static final Logger LOG = LoggerFactory.getLogger(SyncMain.class);

    private SyncMain() {}

    public static void main(String[] args) throws IOException, InterruptedException {
        if (args.length == 0 || args.length > 2 || (args.length == 2 && !"replay".equals(args[0]))) {
            throw new IllegalArgumentException("Usage: SyncMain worker | replay [file] | backfill | rebuild");
        }
        Settings settings = Settings.fromEnvironment();
        if (!"hybrid".equals(settings.mode()) || !settings.local()) {
            throw new IllegalArgumentException("SyncMain requires DATABASE_TYPE=hybrid and local application settings");
        }
        String command = args[0];
        String file = args.length == 2 ? args[1] : null;
        var state = new SyncState(Path.of(System.getenv().getOrDefault("SYNC_STATE_DIR", ".local/sync")));
        try (var repository = new PostgresRepository(settings)) {
            switch (command) {
                case "worker" -> runWorker(settings, repository, state);
                case "replay" -> replay(repository, state, file);
                case "backfill", "rebuild" -> synchronize(settings, repository, state, command);
                default -> throw new IllegalArgumentException("Unsupported sync command: " + command);
            }
        }
    }

    private static void runWorker(Settings settings, PostgresRepository repository, SyncState state)
        throws IOException, InterruptedException {
        String arn;
        try (var client = DynamoSupport.client(settings)) {
            var table = client.describeTable(request -> request.tableName(settings.table())).table();
            var specification = table.streamSpecification();
            arn = table.latestStreamArn();
            if (arn == null || specification == null || !Boolean.TRUE.equals(specification.streamEnabled())
                || specification.streamViewType() != StreamViewType.NEW_AND_OLD_IMAGES) {
                throw new IllegalStateException("The hybrid product table requires NEW_AND_OLD_IMAGES Streams");
            }
        }
        try (var streams = DynamoSupport.streams(settings)) {
            new LocalStreamWorker(streams, repository, state).run(arn);
        }
    }

    private static void replay(PostgresRepository repository, SyncState state, String file) throws IOException {
        for (Path path : state.failed(file)) {
            var record = state.readFailure(path);
            ProductChanges.apply(repository, record.operation(), record.image());
            state.markReplayed(path);
            LOG.info("operation=stream_replay sequence={} file={}", record.sequence(), path.getFileName());
        }
    }

    private static void synchronize(Settings settings, PostgresRepository repository, SyncState state, String command)
        throws IOException {
        try (var workerLock = state.lockWorker(); var client = DynamoSupport.client(settings)) {
            if ("rebuild".equals(command)) {
                repository.rebuild(sink -> scan(client, settings.table(), sink));
                state.resetCheckpoints();
            } else {
                scan(client, settings.table(), repository::project);
            }
        }
        LOG.info("operation={} outcome=complete", command);
    }

    private static void scan(DynamoDbClient client, String table, Consumer<Product> accept) {
        var request = ScanRequest.builder().tableName(table).consistentRead(true).limit(100).build();
        for (var page : client.scanPaginator(request)) {
            page.items().forEach(item -> accept.accept(DynamoSupport.decode(item)));
        }
    }
}
