package cookbook.batch.database;

import java.io.InputStream;
import java.io.OutputStream;
import java.sql.Connection;
import java.sql.PreparedStatement;
import javax.sql.DataSource;
import org.postgresql.PGConnection;

public final class PgCopy {
    private final DataSource dataSource;

    public PgCopy(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public long exportCustomers(String job, String run, boolean tsv, boolean header, OutputStream out)
            throws Exception {
        String sql = """
                COPY (SELECT customer_id AS id, name, email, status FROM batch_customer_export
                    WHERE job_name=current_setting('batch.job_name') AND run_id=current_setting('batch.run_id')
                    AND artifact='copy-customers' ORDER BY customer_id)
                TO STDOUT WITH (FORMAT CSV, ENCODING 'UTF8'
                """ + options(tsv, header);
        return copy(job, run, connection -> connection.getCopyAPI().copyOut(sql, out));
    }

    public long importCustomers(String job, String run, boolean tsv, boolean header, InputStream in,
                                long expectedRows, InputValidation validation) throws Exception {
        String sql = """
                COPY batch_copy_stage(id_text,name,email,status) FROM STDIN
                WITH (FORMAT CSV, ENCODING 'UTF8'
                """ + options(tsv, header);
        return copy(job, run, connection -> {
            long rows = connection.getCopyAPI().copyIn(sql, in);
            validation.verify();
            if (rows != expectedRows) {
                throw new IllegalStateException("COPY did not receive its expected row count");
            }
            return rows;
        });
    }

    private static String options(boolean tsv, boolean header) {
        return (tsv ? ", DELIMITER E'\\t'" : "") + (header ? ", HEADER true)" : ")");
    }

    private long copy(String job, String run, Operation operation) throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(false);
            try {
                try (PreparedStatement settings = connection.prepareStatement(
                        "SELECT set_config('batch.job_name',?,true),set_config('batch.run_id',?,true)")) {
                    settings.setString(1, job);
                    settings.setString(2, run);
                    settings.execute();
                }
                long rows = operation.run(connection.unwrap(PGConnection.class));
                connection.commit();
                return rows;
            } catch (Exception e) {
                connection.rollback();
                throw e;
            }
        }
    }

    @FunctionalInterface
    public interface InputValidation {
        void verify() throws Exception;
    }

    @FunctionalInterface
    private interface Operation {
        long run(PGConnection connection) throws Exception;
    }
}
