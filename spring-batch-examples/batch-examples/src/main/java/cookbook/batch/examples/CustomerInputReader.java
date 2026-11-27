package cookbook.batch.examples;

import cookbook.batch.file.DelimitedFiles;
import cookbook.batch.file.DelimitedReader;
import cookbook.batch.file.FileSettings;
import java.util.List;
import org.springframework.batch.infrastructure.item.ExecutionContext;
import org.springframework.batch.infrastructure.item.ItemStreamException;
import org.springframework.batch.infrastructure.item.ItemStreamReader;
import org.springframework.jdbc.core.JdbcTemplate;

final class CustomerInputReader implements ItemStreamReader<InputCustomer> {
    static final List<String> CUSTOMER_COLUMNS = List.of("id", "name", "email", "status");
    private final RunContext run;
    private final JobFiles files;
    private final JdbcTemplate jdbc;
    private int fileIndex;
    private long ordinal;
    private long errors;
    private CheckedInput stored;
    private DelimitedReader reader;
    private FileSettings settings;
    private List<String> columns;

    CustomerInputReader(RunContext run, JobFiles files, JdbcTemplate jdbc) {
        this.run = run;
        this.files = files;
        this.jdbc = jdbc;
    }

    @Override
    public void open(ExecutionContext state) throws ItemStreamException {
        fileIndex = state.getInt("input.fileIndex", 0);
        ordinal = state.getLong("input.ordinal", 0L);
        errors = state.getLong("input.errors", 0L);
        if (fileIndex < files.pinList().size()) {
            try {
                openFile();
                for (long i = 0; i < ordinal; i++) {
                    run.checkStop();
                    if (reader.read() == null) {
                        throw new IllegalStateException("Checkpoint is past EOF");
                    }
                }
            } catch (Exception error) {
                close();
                throw new ItemStreamException("Could not open pinned input at logical checkpoint", error);
            }
        }
    }

    @Override
    public void update(ExecutionContext state) {
        state.putInt("input.fileIndex", fileIndex);
        state.putLong("input.ordinal", ordinal);
        state.putLong("input.errors", errors);
    }

    @Override
    public InputCustomer read() throws Exception {
        while (fileIndex < files.pinList().size()) {
            run.checkStop();
            if (reader == null) {
                openFile();
            }
            List<String> line = reader.read();
            if (line != null) {
                ordinal++;
                return parse(line);
            }
            var pinned = files.pinList().get(fileIndex);
            String sha256 = stored.verify(pinned.size());
            if (ordinal != files.expectedRows(fileIndex)) {
                throw new IllegalStateException("Input logical row count does not match");
            }
            jdbc.update("""
                    INSERT INTO batch_input_check (job_name,run_id,file_index,row_count,sha256)
                    VALUES (?,?,?,?,?) ON CONFLICT (job_name,run_id,file_index) DO NOTHING
                    """, run.job(), run.runId(), fileIndex, ordinal, sha256);
            close();
            ordinal = 0;
            fileIndex++;
        }
        return null;
    }

    private void openFile() throws Exception {
        settings = files.inputSettings(fileIndex);
        List<String> defaults = run.job().equals("CustomerDelete") ? List.of("id", "version") : CUSTOMER_COLUMNS;
        columns = settings.columnsOr(defaults);
        if (!columns.contains("id") || !List.of("id", "name", "email", "status", "version").containsAll(columns)) {
            throw new IllegalArgumentException("Input columns must include id and use supported names");
        }
        stored = files.checkedInput(fileIndex);
        try {
            reader = DelimitedFiles.reader(stored, settings);
            reader.requireHeader(columns);
        } catch (Exception error) {
            close();
            throw error;
        }
    }

    private InputCustomer parse(List<String> row) {
        try {
            if (row.size() != columns.size()) {
                throw new IllegalArgumentException("wrong column count");
            }
            long id = integer(get(row, "id"));
            if (id <= 0) {
                throw new IllegalArgumentException("id must be positive");
            }
            String name = get(row, "name");
            String email = get(row, "email");
            String status = get(row, "status");
            String version = get(row, "version");
            Long oldVersion = version == null ? null : integer(version);
            if ("CustomerDelete".equals(run.job())) {
                if (oldVersion == null || oldVersion < 0) {
                    throw new IllegalArgumentException("delete requires nonnegative version");
                }
            } else if (name == null || name.isBlank() || status == null || !List.of("ACTIVE", "INACTIVE").contains(status)
                    || email != null && !email.isEmpty() && !email.contains("@")) {
                throw new IllegalArgumentException("invalid name, status or email");
            }
            return new InputCustomer(run.job(), run.runId(), fileIndex, ordinal, id, name, email,
                    status, oldVersion, null);
        } catch (IllegalArgumentException | ArithmeticException error) {
            if (++errors > run.integer("skipLimit", 0, 0, 10000)) {
                throw new IllegalArgumentException("Input record " + ordinal + " exceeds error limit", error);
            }
            return new InputCustomer(run.job(), run.runId(), fileIndex, ordinal, 0,
                    null, null, null, null, error.getMessage());
        }
    }

    private long integer(String value) {
        if (value == null) {
            throw new IllegalArgumentException("id is required");
        }
        return settings.parseNumber(value).longValueExact();
    }

    private String get(List<String> row, String name) {
        int index = columns.indexOf(name);
        return index < 0 ? null : row.get(index);
    }

    @Override
    public void close() throws ItemStreamException {
        try {
            if (reader != null) {
                reader.close();
            } else if (stored != null) {
                stored.close();
            }
        } catch (Exception error) {
            throw new ItemStreamException("Could not close pinned input", error);
        } finally {
            reader = null;
            stored = null;
        }
    }
}
