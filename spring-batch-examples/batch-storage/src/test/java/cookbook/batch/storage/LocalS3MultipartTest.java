package cookbook.batch.storage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.URI;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Collectors;
import java.util.zip.GZIPOutputStream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.S3Exception;

@EnabledIfEnvironmentVariable(named = "BATCH_S3_TEST_ENDPOINT", matches = ".+")
class LocalS3MultipartTest {
    private static final int PART_SIZE = 5 * MultipartLimits.MIB;
    private static final MultipartLimits PARALLEL = new MultipartLimits(PART_SIZE, 2, 2);
    private static final byte[] FIXTURE = {3, 7, 11};

    @Test
    void parallelFanOutUsesOrderedIdenticalBytesAndKeepsSuccessfulDestinationOnFailure() throws Exception {
        try (S3Clients s3 = local()) {
            List<Destination> destinations = destinations(s3.client());
            String run = UUID.randomUUID().toString();
            var ledger = new RecordingArtifactLedger();
            var calls = new AtomicInteger();
            var size = 2L * PART_SIZE + 7;
            var faults = (TransferFaults) (phase, target, part) -> {
                if (phase == TransferFaults.Phase.UPLOAD_PART && target.destination().equals("partner") && part == 2) {
                    throw new IOException("Injected partner part failure");
                }
            };
            ArtifactProducer producer = out -> {
                calls.incrementAndGet();
                writePattern(out, size);
                return 100;
            };

            try (var exporter = new MultipartExporter(ledger, PARALLEL, faults)) {
                assertThrows(IOException.class, () -> exporter.export(run, "fanout", run + "/fanout.bin",
                        "application/octet-stream", destinations, true, producer));
            }
            ArtifactTarget internal = target(run, "fanout", "fanout.bin", destinations.getFirst());
            ArtifactTarget partner = target(run, "fanout", "fanout.bin", destinations.getLast());
            assertTrue(ledger.find(internal).orElseThrow().complete());
            assertFalse(ledger.find(partner).orElseThrow().complete());
            assertEquals(0, s3.client().listMultipartUploads(request ->
                    request.bucket(partner.bucket()).prefix(partner.key())).uploads().size());

            try (var exporter = new MultipartExporter(ledger, PARALLEL)) {
                Map<ArtifactTarget, ArtifactResult> result = exporter.export(run, "fanout", run + "/fanout.bin",
                                "application/octet-stream", destinations, true, producer).stream()
                        .collect(Collectors.toMap(ArtifactResult::target, entry -> entry));
                assertEquals(2, calls.get());
                assertEquals(2, result.size());
                assertEquals(result.get(internal).bytes(), result.get(partner).bytes());
                assertEquals(size, result.get(internal).bytes().size());
                MessageDigest reference = MessageDigest.getInstance("SHA-256");
                writePattern(new java.security.DigestOutputStream(OutputStream.nullOutputStream(), reference), size);
                String expected = HexFormat.of().formatHex(reference.digest());
                assertEquals(expected, result.get(internal).bytes().sha256());
                assertEquals(expected, digestObject(s3.client(), internal));
                assertEquals(expected, digestObject(s3.client(), partner));
            }
        }
    }

    @Test
    void reconcilesCompleteBeforeLedgerCrashAndDoesNotRegenerateDirectExport() throws Exception {
        try (S3Clients s3 = local()) {
            List<Destination> destinations = List.of(destinations(s3.client()).getFirst());
            String run = UUID.randomUUID().toString();
            var ledger = new RecordingArtifactLedger();
            var faults = (TransferFaults) (phase, target, part) -> {
                if (phase == TransferFaults.Phase.OBJECT_COMPLETE) {
                    throw new IOException("Injected loss of database acknowledgement after Complete");
                }
            };
            try (var exporter = new MultipartExporter(ledger, PARALLEL, faults)) {
                assertThrows(IOException.class, () -> exporter.export(run, "gzip", run + "/data.csv.gz",
                        "application/gzip", destinations, false, out -> {
                            try (GZIPOutputStream gzip = new GZIPOutputStream(out)) {
                                gzip.write(FIXTURE);
                            }
                            return 1;
                        }));
            }
            ArtifactTarget target = target(run, "gzip", "data.csv.gz", destinations.getFirst());
            assertFalse(ledger.find(target).orElseThrow().complete());
            assertEquals(digestObject(s3.client(), target), ledger.find(target).orElseThrow().bytes().sha256());

            try (var exporter = new MultipartExporter(ledger, PARALLEL)) {
                assertEquals(1, exporter.export(run, "gzip", run + "/data.csv.gz", "application/gzip", destinations,
                        false, out -> { throw new AssertionError("Completed object should be reconciled"); }).size());
                assertTrue(ledger.find(target).orElseThrow().complete());
                var empty = exporter.export(run, "empty", run + "/empty", "text/csv", destinations, true, out -> 0);
                assertEquals(0, empty.getFirst().bytes().size());
                assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                        empty.getFirst().bytes().sha256());
                var exact = exporter.export(run, "exact", run + "/exact", "application/octet-stream",
                        destinations, true, out -> {
                            writePattern(out, PART_SIZE);
                            return 1;
                        }).getFirst();
                assertEquals(PART_SIZE, exact.bytes().size());
                assertEquals(exact.bytes().sha256(), digestObject(s3.client(), exact.target()));
            }
        }
    }

    @Test
    void pinnedVersionSurvivesOverwriteAndUnversionedPinRejectsIt() throws Exception {
        try (S3Clients s3 = local()) {
            S3Client client = s3.client();
            Destination internal = destinations(client).getFirst();
            String key = internal.key(UUID.randomUUID() + "/input.txt");
            client.putObject(request -> request.bucket(internal.bucket()).key(key), RequestBody.fromBytes(FIXTURE));
            InputObjectVersion pinned = InputObjects.pin(client, internal.bucket(), key);
            InputObjectVersion eTagOnly = new InputObjectVersion(pinned.bucket(), pinned.key(), null, pinned.eTag(),
                    pinned.size());

            client.putObject(request -> request.bucket(internal.bucket()).key(key), RequestBody.fromString("new"));
            assertEquals(412, assertThrows(S3Exception.class, () -> InputObjects.open(client, eTagOnly)).statusCode());
            assertTrue(pinned.versionId() != null && !pinned.versionId().isBlank());
            try (var stream = InputObjects.open(client, pinned)) {
                assertEquals(3, stream.read());
                assertEquals(7, stream.read());
                assertEquals(11, stream.read());
                assertEquals(-1, stream.read());
            }
        }
    }

    @Test
    void failureBeforeCompleteRequiresFixedSourceAndRejectsDifferentRegeneratedBytes() throws Exception {
        try (S3Clients s3 = local()) {
            Destination internal = destinations(s3.client()).getFirst();
            List<Destination> destinations = List.of(internal);
            String run = UUID.randomUUID().toString();
            String key = run + "/version.txt";
            var ledger = new RecordingArtifactLedger();
            var faults = (TransferFaults) (phase, target, part) -> {
                if (phase == TransferFaults.Phase.EXPECTED_COMMITTED) {
                    throw new IOException("Injected process loss before Complete");
                }
            };
            ArtifactProducer original = out -> {
                out.write(FIXTURE);
                return 1;
            };
            try (var exporter = new MultipartExporter(ledger, PARALLEL, faults)) {
                assertThrows(IOException.class,
                        () -> exporter.export(run, "before-complete", key, "text/plain", destinations, true, original));
            }
            try (var exporter = new MultipartExporter(ledger, PARALLEL)) {
                assertThrows(IllegalStateException.class, () ->
                        exporter.export(run, "before-complete", key, "text/plain", destinations, false, original));
                assertThrows(IllegalStateException.class, () ->
                        exporter.export(run, "before-complete", key, "text/plain", destinations, true, out -> {
                            out.write(5);
                            return 1;
                        }));
                assertEquals(1, exporter.export(run, "before-complete", key, "text/plain", destinations, true,
                        original).size());
            }
        }
    }

    @Test
    void slowPartnerKeepsBothBuffersUntilReleasedAndCancellationAborts() throws Exception {
        try (S3Clients s3 = local()) {
            List<Destination> destinations = destinations(s3.client());
            String run = UUID.randomUUID().toString();
            String key = run + "/cancel.bin";
            var bothPartnerPartsReady = new CountDownLatch(2);
            var letPartnerProceed = new CountDownLatch(1);
            var producerFinished = new AtomicBoolean();
            var failure = new AtomicReference<Throwable>();
            var faults = (TransferFaults) (phase, target, part) -> {
                if (phase == TransferFaults.Phase.UPLOAD_PART && target.destination().equals("partner")) {
                    bothPartnerPartsReady.countDown();
                    try {
                        if (!letPartnerProceed.await(20, TimeUnit.SECONDS)) {
                            throw new IOException("Test did not release the slow destination");
                        }
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        throw new InterruptedIOException();
                    }
                }
            };
            try (var exporter = new MultipartExporter(new RecordingArtifactLedger(), PARALLEL, faults)) {
                Thread producer = Thread.ofVirtual().start(() -> {
                    try {
                        exporter.export(run, "cancel", key, "application/octet-stream", destinations, true, out -> {
                            writePattern(out, 3L * PART_SIZE);
                            producerFinished.set(true);
                            return 3;
                        });
                    } catch (Exception | Error e) {
                        failure.set(e);
                    }
                });
                try {
                    assertTrue(bothPartnerPartsReady.await(20, TimeUnit.SECONDS));
                    assertFalse(producerFinished.get(), "Generation must wait for a shared buffer");
                } finally {
                    producer.interrupt();
                    letPartnerProceed.countDown();
                    producer.join(20_000);
                }
                assertFalse(producer.isAlive(), "Cancelled generation and uploads must unwind");
                assertTrue(failure.get() instanceof InterruptedIOException);
                for (Destination destination : destinations) {
                    assertEquals(0, s3.client().listMultipartUploads(request ->
                            request.bucket(destination.bucket()).prefix(destination.key(key))).uploads().size());
                }
            }
        }
    }

    @Test
    void serverSideCopyUsesPinnedVersionAndVerifiesStoredBytes() throws Exception {
        try (S3Clients s3 = local()) {
            S3Client client = s3.client();
            List<Destination> destinations = destinations(client);
            Destination internal = destinations.getFirst();
            String run = UUID.randomUUID().toString();
            String sourceKey = internal.key(run + "/入力 ' source.bin");
            client.putObject(request -> request.bucket(internal.bucket()).key(sourceKey),
                    RequestBody.fromBytes(FIXTURE));
            InputObjectVersion source = InputObjects.pin(client, internal.bucket(), sourceKey);
            client.putObject(request -> request.bucket(internal.bucket()).key(sourceKey),
                    RequestBody.fromString("new source"));
            String hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(FIXTURE));
            String targetKey = run + "/copied.bin";
            try (var exporter = new MultipartExporter(new RecordingArtifactLedger(), PARALLEL)) {
                assertThrows(IOException.class, () -> exporter.copy(run, "copy", targetKey,
                        "application/octet-stream", destinations, client, source, "0".repeat(64)));
                var copied = exporter.copy(run, "copy", targetKey, "application/octet-stream", destinations,
                        client, source, hash);
                assertEquals(2, copied.size());
                for (var result : copied) {
                    assertEquals(new ArtifactBytes(0, FIXTURE.length, hash), result.bytes());
                    assertEquals(hash, digestObject(client, result.target()));
                }
                assertEquals(copied, exporter.copy(run, "copy", targetKey, "application/octet-stream",
                        destinations, client, source, hash));
            }
        }
    }

    private static S3Clients local() {
        return S3Clients.local("us-east-1", URI.create(System.getenv("BATCH_S3_TEST_ENDPOINT")),
                env("BATCH_S3_ACCESS_KEY", "localcookbook"), env("BATCH_S3_SECRET_KEY", "localcookbooksecret"));
    }

    private static List<Destination> destinations(S3Client client) {
        return List.of(
                new Destination("internal", env("BATCH_INTERNAL_BUCKET", "batch-internal"), "storage-test", client),
                new Destination("partner", env("BATCH_PARTNER_BUCKET", "batch-partner"), "storage-test", client));
    }

    private static String env(String name, String fallback) {
        return System.getenv().getOrDefault(name, fallback);
    }

    private static ArtifactTarget target(String run, String id, String file, Destination destination) {
        return new ArtifactTarget(run, id, destination.id(), destination.bucket(), destination.key(run + "/" + file));
    }

    private static String digestObject(S3Client client, ArtifactTarget target) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        var version = InputObjects.pin(client, target.bucket(), target.key());
        try (var stream = InputObjects.open(client, version);
             var output = new java.security.DigestOutputStream(OutputStream.nullOutputStream(), digest)) {
            stream.transferTo(output);
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private static void writePattern(OutputStream output, long size) throws IOException {
        byte[] buffer = new byte[64 * 1024];
        int block = 0;
        for (long left = size; left > 0; left -= buffer.length) {
            Arrays.fill(buffer, (byte) block++);
            output.write(buffer, 0, (int) Math.min(left, buffer.length));
        }
    }
}
