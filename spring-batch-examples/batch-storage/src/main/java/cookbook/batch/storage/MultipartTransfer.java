package cookbook.batch.storage;

import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** The process-wide pool includes producer, queued and in-flight buffers. */
final class MultipartTransfer implements AutoCloseable {
    private static final System.Logger LOG = System.getLogger(MultipartTransfer.class.getName());

    private final MultipartLimits limits;
    private final Semaphore bufferPermits;
    private final ConcurrentLinkedQueue<byte[]> freeBuffers = new ConcurrentLinkedQueue<>();
    private final ThreadPoolExecutor workers;

    MultipartTransfer(MultipartLimits limits) {
        this.limits = limits;
        if ((long) limits.partSize() * limits.buffers() > Runtime.getRuntime().maxMemory() / 2) {
            throw new IllegalArgumentException("S3 part buffers may use at most half the JVM heap");
        }
        bufferPermits = new Semaphore(limits.buffers(), true);
        AtomicInteger workerNumber = new AtomicInteger();
        workers = limits.transferParallelism() == 1 ? null : new ThreadPoolExecutor(
                limits.transferParallelism(), limits.transferParallelism(), 0, TimeUnit.SECONDS,
                new ArrayBlockingQueue<>(limits.buffers()), action -> {
                    Thread worker = new Thread(action, "s3-transfer-" + workerNumber.incrementAndGet());
                    worker.setDaemon(true);
                    return worker;
                });
    }

    ArtifactBytes write(List<S3ArtifactPublication> destinations, ArtifactProducer producer) throws Exception {
        try (var parts = new PartStream(destinations)) {
            long rows = producer.writeTo(new FilterOutputStream(parts) {
                @Override
                public void write(byte[] bytes, int offset, int length) throws IOException {
                    out.write(bytes, offset, length);
                }

                @Override
                public void close() {
                    // A producer can close its compression and text wrappers before publication.
                }
            });
            return parts.finish(rows);
        }
    }

    private byte[] acquire() throws InterruptedIOException {
        try {
            bufferPermits.acquire();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new InterruptedIOException("Interrupted waiting for an S3 part buffer");
        }
        byte[] buffer = freeBuffers.poll();
        if (buffer != null) {
            return buffer;
        }
        try {
            return new byte[limits.partSize()];
        } catch (Error e) {
            bufferPermits.release();
            throw e;
        }
    }

    private void release(byte[] buffer) {
        freeBuffers.add(buffer);
        bufferPermits.release();
    }

    @Override
    public void close() {
        if (workers != null) {
            workers.shutdown();
            try {
                if (!workers.awaitTermination(35, TimeUnit.SECONDS)) {
                    LOG.log(System.Logger.Level.WARNING, "S3 transfer workers are still stopping");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        freeBuffers.clear();
    }

    private final class PartStream extends OutputStream {
        private final List<S3ArtifactPublication> pending;
        private final MessageDigest digest = S3Digests.newSha256();
        private byte[] currentBuffer;
        private int bytesInBuffer;
        private int partCount;
        private long bytesWritten;
        private int outstandingParts;
        private volatile boolean cancelled;
        private Throwable workerFailure;
        private boolean finished;

        PartStream(List<S3ArtifactPublication> pending) {
            this.pending = pending;
        }

        @Override
        public void write(int value) throws IOException {
            requireBuffer();
            currentBuffer[bytesInBuffer++] = (byte) value;
            digest.update((byte) value);
            bytesWritten++;
            if (bytesInBuffer == currentBuffer.length) {
                dispatch();
            }
        }

        @Override
        public void write(byte[] bytes, int offset, int length) throws IOException {
            Objects.checkFromIndexSize(offset, length, bytes.length);
            while (length > 0) {
                requireBuffer();
                int copied = Math.min(length, currentBuffer.length - bytesInBuffer);
                System.arraycopy(bytes, offset, currentBuffer, bytesInBuffer, copied);
                digest.update(bytes, offset, copied);
                bytesInBuffer += copied;
                bytesWritten += copied;
                offset += copied;
                length -= copied;
                if (bytesInBuffer == currentBuffer.length) {
                    dispatch();
                }
            }
        }

        private void requireBuffer() throws IOException {
            checkTransferState();
            if (currentBuffer == null) {
                if (partCount == limits.maxParts()) {
                    throw new IOException("Compressed output exceeds the configured S3 part count");
                }
                currentBuffer = acquire();
            }
        }

        private void dispatch() throws IOException {
            if (partCount == 0) {
                pending.forEach(S3ArtifactPublication::startMultipart);
                checkTransferState();
            }
            byte[] buffer = currentBuffer;
            int length = bytesInBuffer;
            int part = ++partCount;
            currentBuffer = null;
            bytesInBuffer = 0;

            synchronized (this) {
                outstandingParts++;
            }
            Runnable upload = () -> {
                try {
                    for (S3ArtifactPublication target : pending) {
                        if (cancelled) {
                            break;
                        }
                        target.uploadPart(part, buffer, length);
                    }
                } catch (Error e) {
                    synchronized (this) {
                        workerFailure = e;
                        cancelled = true;
                    }
                } finally {
                    release(buffer);
                    partFinished();
                }
            };
            if (workers == null) {
                upload.run();
            } else {
                try {
                    workers.execute(upload);
                } catch (RuntimeException e) {
                    release(buffer);
                    partFinished();
                    throw e;
                }
            }
        }

        private synchronized void partFinished() {
            outstandingParts--;
            notifyAll();
        }

        private synchronized void checkTransferState() throws IOException {
            if (Thread.currentThread().isInterrupted()) {
                throw new InterruptedIOException("Interrupted writing an S3 artifact");
            }
            if (workerFailure != null) {
                throw new IOException("Unrecoverable S3 transfer worker failure", workerFailure);
            }
            if (pending.stream().allMatch(target -> target.transferFailure() != null)) {
                IOException error = new IOException("No remaining S3 artifact destinations");
                pending.forEach(target -> error.addSuppressed(target.transferFailure()));
                throw error;
            }
        }

        private synchronized void awaitTransfers() {
            boolean interrupted = false;
            while (outstandingParts != 0) {
                try {
                    wait();
                } catch (InterruptedException e) {
                    interrupted = true;
                    cancelled = true;
                }
            }
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }

        ArtifactBytes finish(long rows) throws IOException {
            if (bytesInBuffer > 0) {
                dispatch();
            }
            awaitTransfers();
            checkTransferState();
            finished = true;
            return new ArtifactBytes(rows, bytesWritten, HexFormat.of().formatHex(digest.digest()));
        }

        @Override
        public void close() {
            if (!finished) {
                cancelled = true;
                if (currentBuffer != null) {
                    release(currentBuffer);
                    currentBuffer = null;
                }
                awaitTransfers();
            }
        }
    }
}
