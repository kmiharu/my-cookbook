package cookbook.batch.examples.operations;

import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.function.LongFunction;
import java.util.function.ToLongFunction;

import org.springframework.batch.infrastructure.item.ExecutionContext;
import org.springframework.batch.infrastructure.item.ItemStreamReader;

final class OperationPageReader<T> implements ItemStreamReader<T> {
    private final LongFunction<List<T>> readPage;
    private final ToLongFunction<T> id;
    private Iterator<T> currentPage = Collections.emptyIterator();
    private long lastId;

    OperationPageReader(LongFunction<List<T>> readPage, ToLongFunction<T> id) {
        this.readPage = readPage;
        this.id = id;
    }

    @Override
    public void open(ExecutionContext context) {
        lastId = context.getLong("lastOperationId", 0L);
        currentPage = Collections.emptyIterator();
    }

    @Override
    public T read() {
        if (!currentPage.hasNext()) {
            currentPage = readPage.apply(lastId).iterator();
            if (!currentPage.hasNext()) {
                return null;
            }
        }
        T row = currentPage.next();
        lastId = id.applyAsLong(row);
        return row;
    }

    @Override
    public void update(ExecutionContext context) {
        context.putLong("lastOperationId", lastId);
    }

    @Override
    public void close() {
        currentPage = Collections.emptyIterator();
    }
}
