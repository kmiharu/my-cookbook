package cookbook.batch.examples;

import com.fasterxml.jackson.databind.ObjectMapper;
import cookbook.batch.file.DelimitedFiles;
import cookbook.batch.file.FileSettings;
import cookbook.batch.storage.ArtifactLedger;
import cookbook.batch.storage.ArtifactProducer;
import cookbook.batch.storage.Destination;
import cookbook.batch.storage.InputObjectVersion;
import cookbook.batch.storage.InputObjects;
import cookbook.batch.storage.MultipartExporter;
import cookbook.batch.storage.MultipartLimits;
import cookbook.batch.storage.S3Clients;
import cookbook.batch.storage.TransferFaults;
import java.io.FilterOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.s3.model.S3Exception;

@Component
public final class JobFiles implements AutoCloseable {
    private static final Logger log = LoggerFactory.getLogger(JobFiles.class);
    private final RunContext context;
    private final JdbcTemplate jdbc;
    private final Environment env;
    private final MultipartExporter exporter;
    private final List<S3Clients> clients = new ArrayList<>();
    private List<Destination> destinations;
    private S3Clients input;
    private List<InputObjectVersion> versions;

    public JobFiles(RunContext context, JdbcTemplate jdbc, Environment env, ArtifactLedger ledger) {
        this.context = context;
        this.jdbc = jdbc;
        this.env = env;
        var limits = new MultipartLimits(context.integer("partSize", 8 * MultipartLimits.MIB, 5 * MultipartLimits.MIB, 64 * MultipartLimits.MIB),
                context.integer("transferWorkers", 1, 1, 32),
                context.integer("totalBuffers", 2, 1, 64));
        if (limits.partSize() * (long) limits.buffers() > 128L * MultipartLimits.MIB) {
            throw new IllegalArgumentException("multipart buffers may retain at most 128 MiB");
        }
        this.exporter = new MultipartExporter(ledger, limits, this::transferHook);
    }

    public void export(String artifactId, boolean reproducible, String[] columns, RowProducer producer)
            throws Exception {
        FileSettings spec = output(artifactId);
        List<String> header = spec.columnsOr(List.of(columns));
        int[] order = projection(columns, header);
        exportStream(artifactId, extension(spec), contentType(spec), reproducible, stream -> {
            long[] rows = {0};
            try (var writer = DelimitedFiles.writer(nonclosing(stream), spec)) {
                writer.writeHeader(header);
                producer.produce(values -> {
                    context.checkStop();
                    if (values.size() != columns.length) {
                        throw new IllegalArgumentException("wrong output column count for " + artifactId);
                    }
                    if (spec.columns().isEmpty()) {
                        writer.write(values);
                    } else {
                        List<String> projected = new ArrayList<>(order.length);
                        for (int index : order) {
                            projected.add(values.get(index));
                        }
                        writer.write(projected);
                    }
                    rows[0]++;
                });
            }
            return rows[0];
        });
    }

    public void exportCopy(String artifactId, ArtifactProducer producer) throws Exception {
        FileSettings spec = output(artifactId);
        exportStream(artifactId, extension(spec), contentType(spec), true, stream -> {
            try (var encoded = DelimitedFiles.encode(nonclosing(stream), spec)) {
                return producer.writeTo(encoded);
            }
        });
    }

    public void transfer() throws Exception {
        if (context.value("transferMode", "stream").equals("copy")) {
            for (var result : exporter.copy(context.runId(), context.job() + "/transferred",
                    key("transferred", ".bin"), "application/octet-stream", outputDestinations(),
                    inputClient().client(), pinList().getFirst(), expectedSha(0))) {
                logArtifact("transferred", result);
            }
            return;
        }
        exportStream("transferred", ".bin", "application/octet-stream", true, out -> {
            try (CheckedInput in = checkedInput(0)) {
                byte[] buffer = new byte[64 * 1024];
                for (int length; (length = in.read(buffer)) != -1;) {
                    context.checkStop();
                    out.write(buffer, 0, length);
                }
                in.verify(pinList().getFirst().size());
            }
            return 0;
        });
    }

    public void manifest() throws Exception {
        var rows = jdbc.query("""
                SELECT artifact_id,destination,bucket,object_key,row_count,size_bytes,sha256,version_id,state
                FROM batch_artifact WHERE run_id=? AND starts_with(artifact_id,?)
                    AND artifact_id<>? ORDER BY artifact_id,destination
                """, (rs, index) -> {
                    if (!"COMPLETE".equals(rs.getString(9))) {
                        throw new IllegalStateException("Manifest blocked by incomplete artifact");
                    }
                    Map<String, Object> item = new TreeMap<>();
                    item.put("artifact", rs.getString(1).substring(context.job().length() + 1));
                    item.put("destination", rs.getString(2));
                    item.put("bucket", rs.getString(3));
                    item.put("key", rs.getString(4));
                    item.put("rows", rs.getLong(5));
                    item.put("bytes", rs.getLong(6));
                    item.put("sha256", rs.getString(7));
                    item.put("versionId", rs.getString(8));
                    return item;
                }, context.runId(), context.job() + "/", context.job() + "/manifest");
        if (rows.isEmpty()) {
            throw new IllegalStateException("Manifest has no artifacts");
        }
        exportStream("manifest", ".json", "application/json", true, out -> {
            new ObjectMapper().writeValue(nonclosing(out), new TreeMap<>(Map.of(
                    "job", context.job(), "runId", context.runId(), "artifacts", rows)));
            return rows.size();
        });
    }

    public FileSettings output(String artifactId) {
        return FileSettings.from(context.fileOptions(artifactId), "output");
    }

    public FileSettings inputSettings(int fileIndex) {
        return FileSettings.from(context.fileOptions("input-" + (fileIndex + 1)), "input");
    }

    public synchronized List<InputObjectVersion> pinList() {
        if (versions == null) {
            versions = jdbc.query("""
                    SELECT bucket,object_key,version_id,etag,size_bytes FROM batch_input
                    WHERE job_name=? AND run_id=? ORDER BY file_index
                    """, (rs, i) -> new InputObjectVersion(rs.getString(1), rs.getString(2),
                            rs.getString(3), rs.getString(4), rs.getLong(5)), context.job(), context.runId());
            if (versions.isEmpty()) {
                List<InputObjectVersion> pinned = new ArrayList<>();
                for (String key : inputKeys()) {
                    pinned.add(awaitInput(key));
                }
                for (int i = 0; i < pinned.size(); i++) {
                    var v = pinned.get(i);
                    jdbc.update("INSERT INTO batch_input VALUES (?,?,?,?,?,?,?,?)",
                            context.job(), context.runId(), i, v.bucket(), v.key(), v.versionId(), v.eTag(), v.size());
                }
                versions = List.copyOf(pinned);
            }
        }
        return versions;
    }

    private InputObjectVersion awaitInput(String key) {
        int timeout = context.integer("arrivalTimeoutSeconds", 0, 0, 600);
        long deadline = System.nanoTime() + timeout * 1_000_000_000L;
        String bucket = property("BATCH_INPUT_BUCKET", "batch-input");
        String prefix = property("BATCH_INPUT_PREFIX", "");
        String object = prefix.isEmpty() ? key : prefix.replaceFirst("/+$", "") + "/" + key;
        String marker = context.value("input.readyKey", null);
        for (;;) {
            try {
                context.checkStop();
                if (marker != null) {
                    String ready = prefix.isEmpty() ? marker : prefix.replaceFirst("/+$", "") + "/" + marker;
                    InputObjects.pin(inputClient().client(), bucket, ready);
                }
                return InputObjects.pin(inputClient().client(), bucket, object);
            } catch (S3Exception ex) {
                if (ex.statusCode() != 404 || System.nanoTime() >= deadline) {
                    throw ex;
                }
                try {
                    Thread.sleep(500);
                } catch (InterruptedException stop) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("Stopped while waiting for input", stop);
                }
            } catch (InterruptedException stop) {
                throw new IllegalStateException("Stopped while waiting for input", stop);
            }
        }
    }

    public List<String> inputKeys() {
        String keys = context.value("input.keys", context.value("input.key", ""));
        if (keys.isEmpty()) {
            return List.of();
        }
        return List.of(keys.split(",", -1));
    }

    public InputStream openInput(int fileIndex) {
        return InputObjects.open(inputClient().client(), pinList().get(fileIndex));
    }

    public CheckedInput checkedInput(int fileIndex) {
        return new CheckedInput(openInput(fileIndex), expectedSha(fileIndex), pinList().get(fileIndex).size());
    }

    public String expectedSha(int fileIndex) {
        return context.value("input.sha256", "").split(",", -1)[fileIndex].toLowerCase(java.util.Locale.ROOT);
    }

    public long expectedRows(int fileIndex) {
        String rows = context.value("input.rows", "").split(",", -1)[fileIndex];
        return rows.isEmpty() ? -1 : Long.parseLong(rows);
    }

    private void exportStream(String artifactId, String extension, String contentType,
                              boolean reproducible, ArtifactProducer producer) throws Exception {
        context.checkStop();
        for (var result : exporter.export(context.runId(), context.job() + "/" + artifactId,
                key(artifactId, extension), contentType, outputDestinations(), reproducible, producer)) {
            logArtifact(artifactId, result);
        }
    }

    private String key(String artifactId, String extension) {
        return context.job() + "/" + URLEncoder.encode(context.runId(), StandardCharsets.UTF_8)
                + "/" + artifactId + extension;
    }

    private static void logArtifact(String artifactId, cookbook.batch.storage.ArtifactResult result) {
        log.info("artifact={} destination={} rows={} bytes={} sha256={} key={}", artifactId,
                result.target().destination(), result.bytes().rows(), result.bytes().size(),
                result.bytes().sha256(), result.target().key());
    }

    private synchronized S3Clients inputClient() {
        if (input == null) {
            input = client("INPUT");
        }
        return input;
    }

    private synchronized List<Destination> outputDestinations() {
        if (destinations == null) {
            var selected = context.args().destinations();
            List<Destination> configured = new ArrayList<>();
            if (selected != cookbook.batch.common.BatchArguments.Destinations.PARTNER) {
                configured.add(destination("internal"));
            }
            if (selected != cookbook.batch.common.BatchArguments.Destinations.INTERNAL) {
                configured.add(destination("partner"));
            }
            destinations = List.copyOf(configured);
        }
        return destinations;
    }

    private Destination destination(String id) {
        String name = id.toUpperCase(java.util.Locale.ROOT);
        return new Destination(id, property("BATCH_" + name + "_BUCKET", "batch-" + id),
                property("BATCH_" + name + "_PREFIX", ""), client(name).client());
    }

    private S3Clients client(String name) {
        String endpoint = property("BATCH_S3_ENDPOINT", "");
        String region = property("BATCH_" + name + "_REGION", property("BATCH_INTERNAL_REGION", "us-east-1"));
        S3Clients client;
        if (!endpoint.isEmpty()) {
            if (!env.matchesProfiles("local")) {
                throw new IllegalArgumentException("S3 endpoint override requires the local profile");
            }
            client = S3Clients.local(region, URI.create(endpoint),
                    property("BATCH_S3_ACCESS_KEY", "local-access"),
                    property("BATCH_S3_SECRET_KEY", "local-secret"));
        } else {
            client = S3Clients.aws(region, property("BATCH_" + name + "_ROLE_ARN", ""),
                    property("BATCH_" + name + "_EXTERNAL_ID", ""));
        }
        clients.add(client);
        return client;
    }

    private String property(String key, String fallback) {
        return env.getProperty(key, fallback);
    }

    private void transferHook(TransferFaults.Phase phase, cookbook.batch.storage.ArtifactTarget target,
                              int part) throws java.io.IOException {
        if (context.stopping().get()) {
            throw new java.io.IOException("Stop requested");
        }
        if (env.matchesProfiles("fault-test") && phase.name().equals(property("BATCH_FAULT_PHASE", ""))
                && target.destination().equals(property("BATCH_FAULT_DESTINATION", "partner"))) {
            if (property("BATCH_FAULT_ACTION", "").equals("halt")) {
                Runtime.getRuntime().halt(97);
            }
            throw new java.io.IOException("Injected transfer failure at " + phase + " part " + part);
        }
    }

    private static int[] projection(String[] src, List<String> dest) {
        List<String> source = Arrays.asList(src);
        return dest.stream().mapToInt(column -> {
            int index = source.indexOf(column);
            if (index < 0) {
                throw new IllegalArgumentException("Unknown output column: " + column);
            }
            return index;
        }).toArray();
    }

    private static String extension(FileSettings spec) {
        return (spec.format() == FileSettings.Format.CSV ? ".csv" : ".tsv")
                + (spec.compression() == FileSettings.Compression.GZIP ? ".gz" : "");
    }

    private static String contentType(FileSettings spec) {
        if (spec.compression() == FileSettings.Compression.GZIP) {
            return "application/gzip";
        }
        return spec.format() == FileSettings.Format.CSV ? "text/csv" : "text/tab-separated-values";
    }

    private static OutputStream nonclosing(OutputStream out) {
        return new FilterOutputStream(out) {
            @Override public void write(byte[] values, int offset, int length) throws java.io.IOException {
                out.write(values, offset, length);
            }
            @Override public void close() throws java.io.IOException { flush(); }
        };
    }

    @Override
    public void close() {
        exporter.close();
        clients.forEach(S3Clients::close);
    }

    @FunctionalInterface
    public interface RowProducer { void produce(RowSink sink) throws Exception; }

    @FunctionalInterface
    public interface RowSink { void row(List<String> values) throws Exception; }
}
