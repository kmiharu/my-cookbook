package cookbook.batch.storage;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;
import software.amazon.awssdk.services.s3.S3Client;

/** Reuse one exporter so all artifacts and partitions share the transfer limits. */
public final class MultipartExporter implements AutoCloseable {
    public static final long MAX_COPY_OBJECT_BYTES = 5_000_000_000L;

    private final ArtifactLedger ledger;
    private final MultipartLimits limits;
    private final TransferFaults faults;
    private final MultipartTransfer transfer;

    public MultipartExporter(ArtifactLedger ledger, MultipartLimits limits) {
        this(ledger, limits, TransferFaults.NONE);
    }

    public MultipartExporter(ArtifactLedger ledger, MultipartLimits limits, TransferFaults faults) {
        this.ledger = Objects.requireNonNull(ledger);
        this.limits = Objects.requireNonNull(limits);
        this.faults = Objects.requireNonNull(faults);
        transfer = new MultipartTransfer(limits);
    }

    public List<ArtifactResult> export(
            String runId, String artifactId, String relativeKey, String contentType,
            List<Destination> destinations, boolean reproducible, ArtifactProducer producer
    ) throws Exception {
        ExportAttempt attempt = prepare(runId, artifactId, relativeKey, contentType, destinations);
        if (attempt.pending().isEmpty()) {
            requireSameBytes(attempt.priorBytes(), attempt.results().getFirst().bytes());
            return inDestinationOrder(destinations, attempt.results());
        }
        if (attempt.attemptedPreviously() && !reproducible) {
            throw new IllegalStateException("An incomplete direct export needs a new runId");
        }

        ArtifactBytes produced;
        try {
            for (S3ArtifactPublication upload : attempt.pending()) {
                upload.markUploading();
            }
            produced = transfer.write(attempt.pending(), producer);
            requireSameBytes(attempt.priorBytes(), produced);
        } catch (Exception | Error e) {
            for (S3ArtifactPublication upload : attempt.pending()) {
                upload.abortAndRecordFailure(e);
            }
            throw e;
        }
        return publish(artifactId, destinations, attempt, upload -> upload.publishMultipart(produced));
    }

    /**
     * Verify a pinned source by streaming it once, then let each destination's own
     * client request a server-side copy. The destination principal must also be
     * able to read the source version.
     */
    public List<ArtifactResult> copy(
            String runId, String artifactId, String relativeKey, String contentType,
            List<Destination> destinations, S3Client inputClient, InputObjectVersion source,
            String expectedSha256
    ) throws IOException {
        if (source.size() > MAX_COPY_OBJECT_BYTES) {
            throw new IllegalArgumentException("CopyObject permits at most 5 GB. Choose streaming transfer");
        }
        ArtifactBytes expected = expectedSha256 == null || expectedSha256.isBlank() ? null
                : new ArtifactBytes(0, source.size(), expectedSha256.toLowerCase(Locale.ROOT));
        ExportAttempt attempt = prepare(runId, artifactId, relativeKey, contentType, destinations);
        if (attempt.pending().isEmpty()) {
            ArtifactBytes actual = attempt.results().getFirst().bytes();
            requireSameBytes(attempt.priorBytes(), actual);
            requireInputBytes(expected, actual);
            return inDestinationOrder(destinations, attempt.results());
        }
        ArtifactBytes actual = new ArtifactBytes(0, source.size(), S3Digests.read(inputClient, source));
        requireInputBytes(expected, actual);
        requireSameBytes(attempt.priorBytes(), actual);
        return publish(artifactId, destinations, attempt, upload -> upload.copy(source, actual));
    }

    private static void requireInputBytes(ArtifactBytes expected, ArtifactBytes actual) throws IOException {
        if (expected != null && !expected.equals(actual)) {
            throw new IOException("Source checksum does not match expected SHA-256");
        }
    }

    private ExportAttempt prepare(
            String runId, String artifactId, String relativeKey, String contentType, List<Destination> destinations
    ) throws IOException {
        if (runId == null || runId.isBlank() || artifactId == null || artifactId.isBlank()
                || contentType == null || contentType.isBlank()) {
            throw new IllegalArgumentException("runId, artifactId and contentType are required");
        }
        if (destinations.isEmpty() || destinations.size() > 2
                || destinations.stream().map(Destination::id).distinct().count() != destinations.size()) {
            throw new IllegalArgumentException("Choose one or two distinct destination ids");
        }
        List<S3ArtifactPublication> pending = new ArrayList<>(destinations.size());
        List<ArtifactResult> results = new ArrayList<>(destinations.size());
        List<ArtifactBytes> priorBytes = new ArrayList<>(destinations.size());
        boolean attemptedPreviously = false;
        for (Destination destination : destinations) {
            ArtifactTarget target = new ArtifactTarget(
                    runId, artifactId, destination.id(), destination.bucket(), destination.key(relativeKey));
            Optional<ArtifactLedger.Entry> known = ledger.find(target);
            attemptedPreviously |= known.isPresent();
            known.map(ArtifactLedger.Entry::bytes).ifPresent(priorBytes::add);
            S3ArtifactPublication upload = new S3ArtifactPublication(
                    ledger, faults, limits.partSize(), destination, target, contentType);
            Optional<ArtifactResult> recovered = upload.recover(known.orElse(null));
            if (recovered.isPresent()) {
                results.add(recovered.orElseThrow());
            } else {
                pending.add(upload);
            }
        }
        return new ExportAttempt(pending, results, priorBytes, attemptedPreviously);
    }

    private List<ArtifactResult> publish(String artifactId, List<Destination> destinations, ExportAttempt attempt,
                                         Publication publication) throws IOException {
        IOException failed = null;
        for (S3ArtifactPublication upload : attempt.pending()) {
            try {
                attempt.results().add(publication.commit(upload));
            } catch (Exception e) {
                upload.abortAndRecordFailure(e);
                if (failed == null) {
                    failed = new IOException("S3 artifact destinations incomplete for " + artifactId);
                }
                failed.addSuppressed(new IOException(upload.destinationId() + " failed", e));
            }
        }
        if (failed != null) {
            throw failed;
        }
        return inDestinationOrder(destinations, attempt.results());
    }

    private record ExportAttempt(List<S3ArtifactPublication> pending, List<ArtifactResult> results,
                                 List<ArtifactBytes> priorBytes, boolean attemptedPreviously) {}

    @FunctionalInterface
    private interface Publication {
        ArtifactResult commit(S3ArtifactPublication upload) throws IOException;
    }

    private static List<ArtifactResult> inDestinationOrder(List<Destination> destinations, List<ArtifactResult> results) {
        return destinations.stream()
                .map(destination -> results.stream()
                        .filter(result -> result.target().destination().equals(destination.id()))
                        .findFirst().orElseThrow())
                .toList();
    }

    private static void requireSameBytes(List<ArtifactBytes> priorBytes, ArtifactBytes produced) {
        if (priorBytes.stream().anyMatch(prior -> !prior.equals(produced))) {
            throw new IllegalStateException("Regenerated artifact differs from the previous attempt");
        }
    }

    @Override
    public void close() {
        transfer.close();
    }
}
