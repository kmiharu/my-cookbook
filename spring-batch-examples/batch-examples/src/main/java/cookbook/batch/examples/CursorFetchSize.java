package cookbook.batch.examples;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import org.apache.ibatis.executor.Executor;
import org.apache.ibatis.executor.statement.StatementHandler;
import org.apache.ibatis.mapping.MappedStatement;
import org.apache.ibatis.plugin.Interceptor;
import org.apache.ibatis.plugin.Intercepts;
import org.apache.ibatis.plugin.Invocation;
import org.apache.ibatis.plugin.Signature;
import org.apache.ibatis.session.RowBounds;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component
@Intercepts({
    @Signature(type = Executor.class, method = "queryCursor", args = {MappedStatement.class, Object.class, RowBounds.class}),
    @Signature(type = StatementHandler.class, method = "prepare", args = {Connection.class, Integer.class})
})
final class CursorFetchSize implements Interceptor {
    private final ThreadLocal<String> cursor = new ThreadLocal<>();
    private final RunContext run;

    CursorFetchSize(RunContext run) {
        this.run = run;
    }

    @Override
    public Object intercept(Invocation call) throws Throwable {
        if (call.getTarget() instanceof Executor) {
            cursor.set(((MappedStatement) call.getArgs()[0]).getId());
            try {
                return call.proceed();
            } finally {
                cursor.remove();
            }
        }
        Statement statement = (Statement) call.proceed();
        String mapper = cursor.get();
        if (mapper != null) {
            Connection connection = (Connection) call.getArgs()[0];
            if (connection.getAutoCommit() || statement.getResultSetType() != ResultSet.TYPE_FORWARD_ONLY) {
                statement.close();
                throw new IllegalStateException("Cursor needs autoCommit=false and FORWARD_ONLY: " + mapper);
            }
            statement.setFetchSize(run.fetchSize());
            LoggerFactory.getLogger(CursorFetchSize.class).info(
                    "cursor={} autoCommit=false resultSet=FORWARD_ONLY fetchSize={}", mapper, statement.getFetchSize());
        }
        return statement;
    }
}
