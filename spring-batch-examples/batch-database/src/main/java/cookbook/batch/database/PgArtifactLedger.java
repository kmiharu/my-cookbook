package cookbook.batch.database;

import cookbook.batch.storage.ArtifactBytes;
import cookbook.batch.storage.ArtifactLedger;
import cookbook.batch.storage.ArtifactTarget;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

public final class PgArtifactLedger implements ArtifactLedger {
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transaction;

    public PgArtifactLedger(JdbcTemplate jdbc, PlatformTransactionManager manager) {
        this.jdbc = jdbc;
        this.transaction = new TransactionTemplate(manager);
        this.transaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    @Override
    public Optional<Entry> find(ArtifactTarget target) {
        return jdbc.query("""
                SELECT row_count, size_bytes, sha256, upload_id, version_id, state
                FROM batch_artifact WHERE run_id=? AND artifact_id=? AND destination=?
                    AND bucket=? AND object_key=?
                """, (rs, row) -> new Entry(rs.getString(3) == null ? null
                        : new ArtifactBytes(rs.getLong(1), rs.getLong(2), rs.getString(3)),
                        rs.getString(4), rs.getString(5), rs.getString(6).equals("COMPLETE")),
                target.runId(), target.artifactId(), target.destination(), target.bucket(), target.key())
                .stream().findFirst();
    }

    @Override
    public void uploading(ArtifactTarget target, String uploadId) {
        write(target, null, uploadId, null, "UPLOADING", null);
    }

    @Override
    public void expected(ArtifactTarget target, ArtifactBytes bytes) {
        write(target, bytes, null, null, "EXPECTED", null);
    }

    @Override
    public void completed(ArtifactTarget target, ArtifactBytes bytes, String versionId) {
        write(target, bytes, null, versionId, "COMPLETE", null);
    }

    @Override
    public void failed(ArtifactTarget target, String reason) {
        write(target, null, null, null, "FAILED", reason);
    }

    private void write(ArtifactTarget target, ArtifactBytes bytes, String uploadId, String versionId,
                       String state, String reason) {
        transaction.executeWithoutResult(ignored -> {
            int changed = jdbc.update("""
                    INSERT INTO batch_artifact AS a
                       (run_id, artifact_id, destination, bucket, object_key, upload_id,
                        row_count, size_bytes, sha256, version_id, state, failure)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT (run_id, artifact_id,destination) DO UPDATE SET
                       upload_id=COALESCE(EXCLUDED.upload_id,a.upload_id),
                       row_count=COALESCE(a.row_count,EXCLUDED.row_count),
                       size_bytes=COALESCE(a.size_bytes,EXCLUDED.size_bytes),
                       sha256=COALESCE(a.sha256,EXCLUDED.sha256),
                       version_id=COALESCE(a.version_id,EXCLUDED.version_id),
                       state=CASE WHEN a.state='COMPLETE' THEN a.state ELSE EXCLUDED.state END,
                       failure=CASE WHEN a.state='COMPLETE' THEN a.failure ELSE EXCLUDED.failure END,
                       updated_at=clock_timestamp()
                    WHERE a.bucket=EXCLUDED.bucket AND a.object_key=EXCLUDED.object_key
                       AND (EXCLUDED.sha256 IS NULL OR a.sha256 IS NULL
                         OR (a.sha256=EXCLUDED.sha256 AND a.size_bytes=EXCLUDED.size_bytes
                            AND a.row_count=EXCLUDED.row_count))
                    """, target.runId(), target.artifactId(), target.destination(), target.bucket(),
                    target.key(), uploadId, bytes == null ? null : bytes.rows(),
                    bytes == null ? null : bytes.size(), bytes == null ? null : bytes.sha256(),
                    versionId, state, reason);
            if (changed != 1) {
                throw new IllegalStateException("Artifact destination or expected bytes changed: " + target.key());
            }
        });
    }
}
