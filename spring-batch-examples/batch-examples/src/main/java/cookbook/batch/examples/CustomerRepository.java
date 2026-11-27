package cookbook.batch.examples;

import java.util.function.Supplier;
import org.apache.ibatis.cursor.Cursor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

@Repository
class CustomerRepository {
    private static final Logger log = LoggerFactory.getLogger(CustomerRepository.class);
    private final CustomerMapper mapper;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate read;
    private final TransactionTemplate write;
    private final TransactionTemplate prepare;
    private final RunContext run;

    CustomerRepository(CustomerMapper mapper, JdbcTemplate jdbc, PlatformTransactionManager tx, RunContext run) {
        this.mapper = mapper;
        this.jdbc = jdbc;
        this.run = run;
        read = new TransactionTemplate(tx);
        read.setReadOnly(true);
        write = new TransactionTemplate(tx);
        prepare = new TransactionTemplate(tx);
        prepare.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
    }

    void snapshot(String artifact, boolean members) {
        prepare.executeWithoutResult(status -> {
            if (!beginWork(artifact)) {
                return;
            }
            mapper.snapshot(run.job(), run.runId(), artifact, run.conditions());
            if (members) {
                mapper.snapshotMembers(run.job(), run.runId(), run.conditions());
            }
            ready(artifact);
        });
    }

    void snapshotImported() {
        write.executeWithoutResult(ignored -> {
            if (beginWork("customers")) {
                mapper.snapshotImported(run.job(), run.runId());
                ready("customers");
            }
        });
    }

    void seed() throws InterruptedException {
        long start = run.number("startId", 1, 1, 1_000_000_000_000L);
        long end = start + run.number("rows", 100, 0, 10_000_000) - 1;
        int width = run.integer("rowWidth", 256, 64, 4096);
        int seed = run.integer("seed", 31, 1, 10_000);
        long affected = 0;
        for (long cursor = start; cursor <= end; cursor += 10_000) {
            run.checkStop();
            affected += mapper.seed(cursor, Math.min(cursor + 9_999, end), width, seed);
        }
        log.info("seeded rows={} approximate-width={}", affected, width);
    }

    boolean beginWork(String kind) {
        return jdbc.update("""
                INSERT INTO batch_work_status VALUES (?,?,?,'PREPARING')
                ON CONFLICT (job_name,run_id,work_kind) DO NOTHING
                """, run.job(), run.runId(), kind) == 1;
    }

    void ready(String kind) {
        int changed = jdbc.update("""
                UPDATE batch_work_status SET state='READY'
                WHERE job_name=? AND run_id=? AND work_kind=? AND state='PREPARING'
                """, run.job(), run.runId(), kind);
        if (changed != 1) {
            throw new IllegalStateException("Could not mark work READY: " + kind);
        }
    }

    void direct(CheckedRow<CustomerRow> consumer) throws Exception {
        stream(() -> mapper.selectCustomers(run.conditions()), consumer);
    }

    void work(String artifact, long low, long high, CheckedRow<CustomerRow> consumer) throws Exception {
        stream(() -> mapper.selectWork(run.job(), run.runId(), artifact, low, high), consumer);
    }

    void errors(CheckedRow<CustomerMapper.InputError> consumer) throws Exception {
        stream(() -> mapper.selectErrors(run.job(), run.runId()), consumer);
    }

    private <T> void stream(Supplier<Cursor<T>> select, CheckedRow<T> consumer) throws Exception {
        try {
            read.executeWithoutResult(status -> {
                try (Cursor<T> cursor = select.get()) {
                    for (T row : cursor) {
                        consumer.accept(row);
                    }
                } catch (Exception error) {
                    throw new InterruptedRead(error);
                }
            });
        } catch (InterruptedRead interrupted) {
            throw (Exception) interrupted.getCause();
        }
    }

    @FunctionalInterface
    interface CheckedRow<T> {
        void accept(T row) throws Exception;
    }

    private static final class InterruptedRead extends RuntimeException {
        InterruptedRead(Exception cause) {
            super(cause);
        }
    }
}
