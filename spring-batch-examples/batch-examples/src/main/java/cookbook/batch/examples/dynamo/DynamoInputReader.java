package cookbook.batch.examples.dynamo;

import cookbook.batch.dynamodb.DynamoCustomer;
import cookbook.batch.examples.CheckedInput;
import cookbook.batch.examples.JobFiles;
import cookbook.batch.examples.RunContext;
import cookbook.batch.file.DelimitedFiles;
import cookbook.batch.file.DelimitedReader;
import cookbook.batch.file.FileSettings;
import java.util.HashSet;
import java.util.List;
import org.springframework.batch.infrastructure.item.ExecutionContext;
import org.springframework.batch.infrastructure.item.ItemStreamException;
import org.springframework.batch.infrastructure.item.ItemStreamReader;

final class DynamoInputReader implements ItemStreamReader<DynamoMapper.Work> {
    static final List<String> FULL = List.of("pk", "sk", "version", "status", "balance", "memo_state", "memo");
    static final List<String> DELETE = List.of("pk", "sk", "version");
    static final List<String> ADD = List.of("pk", "sk", "version", "delta");
    private static final String ORDINAL = "dynamo.input.ordinal";
    private final RunContext context;
    private final JobFiles files;
    private final DynamoMapper mapper;
    private final String runKey;
    private final DynamoSettings config;
    private CheckedInput checked;
    private DelimitedReader reader;
    private FileSettings definition;
    private DynamoPlan plan;
    private List<String> expected;
    private List<String> projection;
    private long position;
    private boolean eof;

    DynamoInputReader(RunContext context, JobFiles files, DynamoMapper mapper,
                      String runKey, DynamoSettings config) {
        this.context = context;
        this.files = files;
        this.mapper = mapper;
        this.runKey = runKey;
        this.config = config;
    }

    @Override
    public void open(ExecutionContext executionContext) {
        position = executionContext.getLong(ORDINAL, 0);
        eof = false;
        try {
            definition = files.inputSettings(0);
            plan = DynamoPlan.from(context, config);
            expected = columns(context.job(), plan);
            projection = definition.columnsOr(expected);
            verifyColumns(expected, projection);
            checked = files.checkedInput(0);
            reader = DelimitedFiles.reader(checked, definition);
            if (definition.header()) {
                reader.requireHeader(projection);
            }
            for (long row = 0; row < position; row++) {
                context.checkStop();
                if (reader.read() == null) {
                    throw new IllegalStateException("DynamoDB input ended before its checkpoint");
                }
            }
        } catch (Exception e) {
            try {
                close();
            } catch (ItemStreamException closeFailure) {
                e.addSuppressed(closeFailure);
            }
            throw new ItemStreamException("Opening fixed DynamoDB input failed", e);
        }
    }

    @Override
    public DynamoMapper.Work read() throws Exception {
        context.checkStop();
        if (eof) {
            return null;
        }
        List<String> row = reader.read();
        if (row == null) {
            long expectedRows = files.expectedRows(0);
            if (position != expectedRows) {
                throw new IllegalArgumentException("DynamoDB input logical record count does not match");
            }
            var sha256 = checked.verify(files.pinList().getFirst().size());
            if (mapper.inputEnd(runKey, position, sha256) != 1) {
                throw new IllegalStateException("DynamoDB input work is not PREPARING");
            }
            eof = true;
            return null;
        }
        position++;
        if (row.size() != expected.size()) {
            throw new IllegalArgumentException("Unexpected column count at input record " + position);
        }
        try {
            var key = new DynamoCustomer.Key(required(row, "pk"), required(row, "sk"));
            if (!key.pk().equals(plan.read().partition())) {
                throw new IllegalArgumentException("Input key must belong to the selected partition");
            }
            long version = Long.parseLong(required(row, "version"));
            if (version < 0 || (!context.job().equals("DynamoDbImport") && version == Long.MAX_VALUE)) {
                throw new IllegalArgumentException("Invalid input version");
            }
            if (expected.equals(DELETE)) {
                return new DynamoMapper.Work(runKey, key.pk(), key.sk(), version, null, null, "ABSENT", null, position);
            }
            if (expected.equals(ADD)) {
                var delta = definition.parseNumber(required(row, "delta"));
                new DynamoCustomer(key, version, "probe", delta, DynamoCustomer.Text.absent());
                return new DynamoMapper.Work(runKey, key.pk(), key.sk(), version, null, delta, "ABSENT", null, position);
            }
            var balance = definition.parseNumber(required(row, "balance"));
            String memoState = required(row, "memo_state");
            String memo = cell(row, "memo");
            var customer = new DynamoCustomer(key, version, required(row, "status"), balance, memo(memoState, memo));
            customer.attributes();
            return new DynamoMapper.Work(runKey, key.pk(), key.sk(), version, customer.status(),
                    balance, memoState, memo, position);
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("Invalid DynamoDB input at logical record " + position, e);
        }
    }

    private String required(List<String> row, String name) {
        String result = cell(row, name);
        if (result == null) {
            throw new IllegalArgumentException(name + " must have a value");
        }
        return result;
    }

    private String cell(List<String> row, String name) {
        return row.get(projection.indexOf(name));
    }

    static List<String> columns(String job, DynamoPlan plan) {
        if (job.equals("DynamoDbDelete")) {
            return DELETE;
        }
        if (job.equals("DynamoDbConditionalUpdate") && plan.operation().equals("add")) {
            return ADD;
        }
        return FULL;
    }

    static void verifyColumns(List<String> expected, List<String> projection) {
        if (projection.size() != expected.size() || !new HashSet<>(projection).containsAll(expected)) {
            throw new IllegalArgumentException("DynamoDB input columns do not match the job");
        }
    }

    static DynamoCustomer.Text memo(String memoState, String memo) {
        if ("ABSENT".equals(memoState) && memo == null) {
            return DynamoCustomer.Text.absent();
        }
        if (("NULL".equals(memoState) && memo == null) || ("VALUE".equals(memoState) && memo != null)) {
            return DynamoCustomer.Text.nullable(memo);
        }
        throw new IllegalArgumentException("memo_state must describe the memo as ABSENT, NULL or VALUE");
    }

    @Override
    public void update(ExecutionContext executionContext) {
        executionContext.putLong(ORDINAL, position);
    }

    @Override
    public void close() {
        try {
            if (reader != null) {
                reader.close();
            } else if (checked != null) {
                checked.close();
            }
        } catch (Exception e) {
            throw new ItemStreamException("Closing DynamoDB input failed", e);
        } finally {
            reader = null;
            checked = null;
        }
    }
}
