package cookbook.batch.storage;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.concurrent.ConcurrentSkipListMap;
import java.util.concurrent.atomic.AtomicReference;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.model.CompletedMultipartUpload;
import software.amazon.awssdk.services.s3.model.CompletedPart;
import software.amazon.awssdk.services.s3.model.HeadObjectResponse;
import software.amazon.awssdk.services.s3.model.MetadataDirective;
import software.amazon.awssdk.services.s3.model.S3Exception;

/** The S3 object and durable ledger entry for one destination. */
final class S3ArtifactPublication {
    private static final String IDENTITY_METADATA = "batch-identity";
    private static final System.Logger LOG = System.getLogger(S3ArtifactPublication.class.getName());

    private final ArtifactLedger ledger;
    private final TransferFaults faults;
    private final int partSize;
    private final Destination destination;
    private final ArtifactTarget target;
    private final String contentType;
    private final String identity;
    private final ConcurrentSkipListMap<Integer, CompletedPart> completedParts = new ConcurrentSkipListMap<>();
    private final AtomicReference<Throwable> transferFailure = new AtomicReference<>();
    private String uploadId;

    S3ArtifactPublication(ArtifactLedger ledger, TransferFaults faults, int partSize,
                          Destination destination, ArtifactTarget target, String contentType) {
        this.ledger = ledger;
        this.faults = faults;
        this.partSize = partSize;
        this.destination = destination;
        this.target = target;
        this.contentType = contentType;
        identity = S3Digests.artifactIdentity(target);
    }

    String destinationId() {
        return target.destination();
    }

    Throwable transferFailure() {
        return transferFailure.get();
    }

    void markUploading() {
        ledger.uploading(target, null);
    }

    Optional<ArtifactResult> recover(ArtifactLedger.Entry entry) throws IOException {
        String storedVersion = entry == null ? null : entry.versionId();
        Optional<HeadObjectResponse> existingObject = head(storedVersion);
        ArtifactBytes expected = entry == null ? null : entry.bytes();
        if (existingObject.isPresent()) {
            HeadObjectResponse stored = existingObject.orElseThrow();
            if (expected == null || !identity.equals(stored.metadata().get(IDENTITY_METADATA))
                    || !Objects.equals(stored.contentLength(), expected.size())) {
                throw new IOException("Conflicting S3 artifact at " + target.key());
            }
            InputObjectVersion current = new InputObjectVersion(
                    target.bucket(), target.key(), stored.versionId(), stored.eTag(), stored.contentLength());
            if (!expected.sha256().equals(S3Digests.read(destination.client(), current))) {
                throw new IOException("S3 artifact SHA-256 differs from the ledger at " + target.key());
            }
            if (!entry.complete()) {
                ledger.completed(target, expected, current.versionId());
            }
            return Optional.of(new ArtifactResult(target, expected, current.versionId()));
        }
        if (entry != null) {
            if (entry.complete()) {
                throw new IOException("Completed S3 artifact is unavailable at " + target.key());
            }
            abortQuietly(entry.uploadId());
        }
        return Optional.empty();
    }

    private Optional<HeadObjectResponse> head(String versionId) {
        try {
            return Optional.of(destination.client().headObject(request ->
                    request.bucket(target.bucket()).key(target.key()).versionId(versionId)));
        } catch (S3Exception e) {
            if (e.statusCode() == 404) {
                return Optional.empty();
            }
            throw e;
        }
    }

    void startMultipart() {
        try {
            uploadId = destination.client().createMultipartUpload(request -> request.bucket(target.bucket())
                    .key(target.key()).contentType(contentType).metadata(Map.of(IDENTITY_METADATA, identity)))
                    .uploadId();
            if (uploadId == null || uploadId.isBlank()) {
                throw new IllegalStateException("S3 did not return a multipart upload id");
            }
            ledger.uploading(target, uploadId);
        } catch (RuntimeException e) {
            transferFailure.compareAndSet(null, e);
        }
    }

    void uploadPart(int part, byte[] buffer, int size) {
        if (transferFailure.get() != null) {
            return;
        }
        try {
            faults.hit(TransferFaults.Phase.UPLOAD_PART, target, part);
            RequestBody body = RequestBody.fromContentProvider(
                    () -> new ByteArrayInputStream(buffer, 0, size), size, contentType);
            String eTag = destination.client().uploadPart(request -> request.bucket(target.bucket())
                    .key(target.key()).uploadId(uploadId).partNumber(part).contentLength((long) size), body).eTag();
            if (eTag == null || eTag.isBlank()) {
                throw new IOException("S3 did not return a multipart ETag");
            }
            completedParts.put(part, CompletedPart.builder().partNumber(part).eTag(eTag).build());
        } catch (Exception e) {
            transferFailure.compareAndSet(null, e);
        }
    }

    ArtifactResult publishMultipart(ArtifactBytes bytes) throws IOException {
        Throwable failedTransfer = transferFailure.get();
        if (failedTransfer != null) {
            throw new IOException("S3 part transfer failed", failedTransfer);
        }
        markExpected(bytes);
        String versionId;
        if (bytes.size() == 0) {
            versionId = destination.client().putObject(request -> request.bucket(target.bucket())
                    .key(target.key()).contentType(contentType).metadata(Map.of(IDENTITY_METADATA, identity))
                    .ifNoneMatch("*"), RequestBody.empty()).versionId();
        } else {
            int expectedParts = (int) ((bytes.size() - 1) / partSize + 1);
            if (uploadId == null || completedParts.size() != expectedParts) {
                throw new IOException("Missing completed S3 parts");
            }
            CompletedMultipartUpload multipart = CompletedMultipartUpload.builder()
                    .parts(completedParts.values()).build();
            versionId = destination.client().completeMultipartUpload(request -> request.bucket(target.bucket())
                    .key(target.key()).uploadId(uploadId).multipartUpload(multipart).ifNoneMatch("*")).versionId();
            uploadId = null;
        }
        return confirm(bytes, versionId);
    }

    ArtifactResult copy(InputObjectVersion source, ArtifactBytes bytes) throws IOException {
        markUploading();
        markExpected(bytes);
        String versionId = destination.client().copyObject(request -> request
                .sourceBucket(source.bucket()).sourceKey(source.key())
                .sourceVersionId(source.versionId()).copySourceIfMatch(source.eTag())
                .destinationBucket(target.bucket()).destinationKey(target.key()).ifNoneMatch("*")
                .metadata(Map.of(IDENTITY_METADATA, identity)).metadataDirective(MetadataDirective.REPLACE)
                .contentType(contentType)).versionId();
        return confirm(bytes, versionId);
    }

    private void markExpected(ArtifactBytes bytes) throws IOException {
        if (Thread.currentThread().isInterrupted()) {
            throw new InterruptedIOException("Interrupted before S3 publication");
        }
        ledger.expected(target, bytes);
        faults.hit(TransferFaults.Phase.EXPECTED_COMMITTED, target, 0);
    }

    private ArtifactResult confirm(ArtifactBytes bytes, String versionId) throws IOException {
        faults.hit(TransferFaults.Phase.OBJECT_COMPLETE, target, 0);
        if ("null".equals(versionId)) {
            versionId = null;
        }
        ledger.completed(target, bytes, versionId);
        return new ArtifactResult(target, bytes, versionId);
    }

    private void abortQuietly(String id) {
        if (id == null) {
            return;
        }
        // Cancellation may already have interrupted the producer. Give Abort one bounded attempt.
        boolean interrupted = Thread.interrupted();
        try {
            destination.client().abortMultipartUpload(request ->
                    request.bucket(target.bucket()).key(target.key()).uploadId(id));
        } catch (S3Exception e) {
            if (e.statusCode() != 404) {
                LOG.log(System.Logger.Level.WARNING, "S3 multipart abort failed for {0} ({1})",
                        target.destination(), e.statusCode());
            }
        } catch (RuntimeException e) {
            LOG.log(System.Logger.Level.WARNING, "S3 multipart abort failed for {0} ({1})",
                    target.destination(), e.getClass().getSimpleName());
        } finally {
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    void abortAndRecordFailure(Throwable original) {
        abortQuietly(uploadId);

        try {
            ledger.failed(target, original.getClass().getSimpleName());
        } catch (RuntimeException e) {
            if (original != e) {
                original.addSuppressed(e);
            }
        }
    }
}
