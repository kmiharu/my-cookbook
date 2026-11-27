package cookbook.batch.examples;

import cookbook.batch.database.PgCopy;
import cookbook.batch.file.DelimitedFiles;
import cookbook.batch.file.FileSettings;
import java.util.List;
import javax.sql.DataSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Component
final class CustomerCopy {
    private final PgCopy copy;
    private final RunContext run;
    private final JobFiles files;
    private final JdbcTemplate jdbc;
    private final CustomerMapper mapper;
    private final TransactionTemplate transaction;

    CustomerCopy(DataSource dataSource, RunContext run, JobFiles files, JdbcTemplate jdbc,
                 CustomerMapper mapper, PlatformTransactionManager manager) {
        this.copy = new PgCopy(dataSource);
        this.run = run;
        this.files = files;
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.transaction = new TransactionTemplate(manager);
    }

    void exportCustomers() throws Exception {
        var spec = files.output("customers");
        LaunchOptions.validateCopy(spec);
        files.exportCopy("customers", output -> copy.exportCustomers(run.job(), run.runId(),
                spec.format() == FileSettings.Format.TSV, spec.header(), output));
    }

    void importCustomers() throws Exception {
        var inputs = files.pinList();
        if (inputs.size() != 1) {
            throw new IllegalArgumentException("COPY import accepts one file");
        }
        var settings = files.inputSettings(0);
        long storedSize = inputs.getFirst().size();
        var validated = validateInput(settings, storedSize);

        jdbc.update("DELETE FROM batch_copy_stage WHERE job_name=? AND run_id=?", run.job(), run.runId());
        try (var stored = files.checkedInput(0); var decoded = DelimitedFiles.decode(stored, settings)) {
            copy.importCustomers(run.job(), run.runId(), settings.format() == FileSettings.Format.TSV,
                    settings.header(), decoded, validated.rows(), () -> stored.verify(storedSize));
        }
        transaction.executeWithoutResult(status -> {
            jdbc.update("DELETE FROM batch_input_work WHERE job_name=? AND run_id=?", run.job(), run.runId());
            mapper.promoteCopyRows(run.job(), run.runId());
            jdbc.update("INSERT INTO batch_input_check VALUES (?,?,0,?,?) ON CONFLICT DO NOTHING",
                    run.job(), run.runId(), validated.rows(), validated.sha256());
        });
    }

    private ValidatedInput validateInput(FileSettings settings, long storedSize) throws Exception {
        long count = 0;
        String sha256;
        try (var stored = files.checkedInput(0); var reader = DelimitedFiles.reader(stored, settings)) {
            reader.requireHeader(CustomerInputReader.CUSTOMER_COLUMNS);
            for (List<String> row; (row = reader.read()) != null;) {
                run.checkStop();
                if (row.size() != 4 || row.get(0) == null || Long.parseLong(row.get(0)) <= 0 ||
                        row.get(1) == null || row.get(1).isBlank() || row.get(3) == null ||
                        !List.of("ACTIVE", "INACTIVE").contains(row.get(3))) {
                    throw new IllegalArgumentException("Invalid COPY staging row");
                }
                count++;
            }
            sha256 = stored.verify(storedSize);
        }
        if (count != files.expectedRows(0)) {
            throw new IllegalStateException("COPY logical rows do not match expected total");
        }
        return new ValidatedInput(count, sha256);
    }

    private record ValidatedInput(long rows, String sha256) {}
}
