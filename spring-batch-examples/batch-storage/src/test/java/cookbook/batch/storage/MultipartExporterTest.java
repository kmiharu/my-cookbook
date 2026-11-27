package cookbook.batch.storage;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

import java.io.IOException;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.CompleteMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.CreateMultipartUploadResponse;
import software.amazon.awssdk.services.s3.model.HeadObjectRequest;
import software.amazon.awssdk.services.s3.model.S3Exception;
import software.amazon.awssdk.services.s3.model.UploadPartRequest;
import software.amazon.awssdk.services.s3.model.UploadPartResponse;

class MultipartExporterTest {
    private static final int PART_SIZE = 5 * MultipartLimits.MIB;

    @Test
    void validatesPartSizeAndWorkerLimitsBeforeAllocation() {
        assertThrows(IllegalArgumentException.class, () -> new MultipartLimits(PART_SIZE - 1, 1, 1));
        assertThrows(IllegalArgumentException.class, () -> new MultipartLimits(PART_SIZE, 2, 1));
        assertThrows(IllegalArgumentException.class, () -> new MultipartLimits(PART_SIZE, 1, 1, 10_001));
        assertEquals(83_886_080_000L, new MultipartLimits(8 * MultipartLimits.MIB, 1, 1).maxObjectBytes());
    }

    @Test
    void abortsWithoutCompletingWhenGeneratedBytesExceedPartLimit() throws Exception {
        S3Client client = mock(S3Client.class, Mockito.CALLS_REAL_METHODS);
        doAnswer(invocation -> { throw S3Exception.builder().statusCode(404).build(); })
                .when(client).headObject(any(HeadObjectRequest.class));
        doReturn(CreateMultipartUploadResponse.builder().uploadId("stub").build())
                .when(client).createMultipartUpload(any(software.amazon.awssdk.services.s3.model.CreateMultipartUploadRequest.class));
        doAnswer(invocation -> {
            RequestBody body = invocation.getArgument(1);
            assertEquals(PART_SIZE, body.optionalContentLength().orElseThrow());
            return UploadPartResponse.builder().eTag("part-1").build();
        }).when(client).uploadPart(any(UploadPartRequest.class), any(RequestBody.class));
        doReturn(null).when(client).abortMultipartUpload(
                any(software.amazon.awssdk.services.s3.model.AbortMultipartUploadRequest.class));

        var ledger = new RecordingArtifactLedger();
        var destination = new Destination("internal", "internal", "", client);
        try (var exporter = new MultipartExporter(ledger, new MultipartLimits(PART_SIZE, 1, 1, 1))) {
            IOException error = assertThrows(IOException.class, () -> exporter.export("run", "large", "large.data",
                    "application/octet-stream", List.of(destination), true, out -> {
                        byte[] small = new byte[64 * 1024];
                        for (int written = 0; written < PART_SIZE; written += small.length) {
                            out.write(small);
                        }
                        out.write(42);
                        return 1;
                    }));
            assertTrue(error.getMessage().contains("part count"));
        }
        verify(client, never()).completeMultipartUpload(any(CompleteMultipartUploadRequest.class));
        verify(client).abortMultipartUpload(any(software.amazon.awssdk.services.s3.model.AbortMultipartUploadRequest.class));
    }
}
