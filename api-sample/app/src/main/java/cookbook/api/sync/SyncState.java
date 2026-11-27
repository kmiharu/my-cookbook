package cookbook.api.sync;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

import java.io.IOException;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Properties;

final class SyncState {
    private static final Logger LOG = LoggerFactory.getLogger(SyncState.class);
    private final Path directory;

    SyncState(Path directory) throws IOException {
        this.directory = directory;
        Files.createDirectories(directory.resolve("checkpoints"));
        Files.createDirectories(directory.resolve("failed"));
        Files.createDirectories(directory.resolve("replayed"));
    }

    FileChannel lockWorker() throws IOException {
        FileChannel channel = FileChannel.open(directory.resolve("worker.lock"),
            StandardOpenOption.CREATE, StandardOpenOption.WRITE);
        try {
            if (channel.tryLock() != null) {
                return channel;
            }
            throw new IllegalStateException("Stop the existing worker before using this command");
        } catch (RuntimeException | IOException failure) {
            channel.close();
            throw failure;
        }
    }

    record Checkpoint(String sequence, boolean closed) {}

    Checkpoint checkpoint(String arn, String shard) throws IOException {
        Path path = checkpointPath(arn, shard);
        if (!Files.exists(path)) {
            return new Checkpoint(null, false);
        }
        Properties properties = read(path);
        return new Checkpoint(properties.getProperty("sequence"),
            Boolean.parseBoolean(properties.getProperty("closed")));
    }

    void saveCheckpoint(String arn, String shard, Checkpoint checkpoint) throws IOException {
        var properties = new Properties();
        properties.setProperty("streamArn", arn);
        properties.setProperty("shard", shard);
        if (checkpoint.sequence() != null) {
            properties.setProperty("sequence", checkpoint.sequence());
        }
        properties.setProperty("closed", Boolean.toString(checkpoint.closed()));
        write(checkpointPath(arn, shard), properties);
    }

    void resetCheckpoints() throws IOException {
        Path checkpoints = directory.resolve("checkpoints");
        Path archived = directory.resolve("checkpoints-" + Instant.now().toEpochMilli());
        Files.move(checkpoints, archived, StandardCopyOption.ATOMIC_MOVE);
        Files.createDirectories(checkpoints);
    }

    private Path checkpointPath(String arn, String shard) {
        return directory.resolve("checkpoints").resolve(digest(arn + "\n" + shard) + ".properties");
    }

    void saveFailure(String arn, String shard, String sequence, String operation,
                     Map<String, AttributeValue> image) throws IOException {
        var properties = new Properties();
        properties.setProperty("streamArn", arn);
        properties.setProperty("shard", shard);
        properties.setProperty("sequence", sequence);
        properties.setProperty("operation", operation);
        image.forEach((name, attribute) -> {
            String key = "image." + name + ".";
            if (attribute.s() != null) {
                properties.setProperty(key + "S", attribute.s());
            }
            if (attribute.n() != null) {
                properties.setProperty(key + "N", attribute.n());
            }
            if (attribute.bool() != null) {
                properties.setProperty(key + "BOOL", attribute.bool().toString());
            }
        });
        Path path = directory.resolve("failed").resolve(digest(arn + "\n" + shard + "\n" + sequence) + ".properties");
        if (!Files.exists(path)) {
            write(path, properties);
            LOG.info("operation=stream_spool sequence={} file={}", sequence, path.getFileName());
        }
    }

    List<Path> failed(String name) throws IOException {
        if (name != null) {
            if (!name.matches("[a-f0-9]{64}\\.properties")) {
                throw new IllegalArgumentException("Provide a saved event basename from the failed directory");
            }
            return List.of(directory.resolve("failed").resolve(name));
        }
        try (var paths = Files.list(directory.resolve("failed"))) {
            return paths.filter(path -> path.getFileName().toString().endsWith(".properties")).sorted().toList();
        }
    }

    record FailedEvent(String sequence, String operation, Map<String, AttributeValue> image) {}

    FailedEvent readFailure(Path path) throws IOException {
        Properties properties = read(path);
        var imageFields = new HashMap<String, AttributeValue.Builder>();
        for (String key : properties.stringPropertyNames()) {
            if (!key.startsWith("image.")) {
                continue;
            }
            int separator = key.lastIndexOf('.');
            var builder = imageFields.computeIfAbsent(key.substring("image.".length(), separator),
                ignored -> AttributeValue.builder());
            String value = properties.getProperty(key);
            switch (key.substring(separator + 1)) {
                case "S" -> builder.s(value);
                case "N" -> builder.n(value);
                case "BOOL" -> builder.bool(Boolean.valueOf(value));
                default -> throw new IllegalArgumentException("Unsupported saved attribute type: " + key);
            }
        }
        var image = new HashMap<String, AttributeValue>();
        imageFields.forEach((name, builder) -> image.put(name, builder.build()));
        return new FailedEvent(properties.getProperty("sequence"), properties.getProperty("operation"), image);
    }

    void markReplayed(Path path) throws IOException {
        Files.move(path, directory.resolve("replayed").resolve(path.getFileName()),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    }

    private static Properties read(Path path) throws IOException {
        var properties = new Properties();
        try (var input = Files.newInputStream(path)) {
            properties.load(input);
        }
        return properties;
    }

    private static void write(Path destination, Properties properties) throws IOException {
        Path temporary = Files.createTempFile(destination.getParent(), "event-", ".tmp");
        try {
            try (var file = FileChannel.open(temporary, StandardOpenOption.WRITE)) {
                properties.store(Channels.newOutputStream(file), null);
                file.force(true);
            }
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static String digest(String value) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(hash);
        } catch (NoSuchAlgorithmException failure) {
            throw new IllegalStateException(failure);
        }
    }
}
