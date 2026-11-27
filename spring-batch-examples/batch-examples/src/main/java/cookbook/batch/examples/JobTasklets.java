package cookbook.batch.examples;

import org.springframework.batch.core.job.JobInterruptedException;
import org.springframework.batch.core.step.tasklet.Tasklet;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.interceptor.DefaultTransactionAttribute;

public final class JobTasklets {
    private JobTasklets() {}

    public static Tasklet interruptible(RunContext run, Tasklet action) {
        return (contribution, chunk) -> {
            try {
                run.checkStop();
                return action.execute(contribution, chunk);
            } catch (Exception failure) {
                if (!(failure instanceof InterruptedException) && !run.stopping().get()) {
                    throw failure;
                }
                contribution.getStepExecution().setTerminateOnly();
                var stop = new JobInterruptedException("Stop requested");
                stop.addSuppressed(failure);
                throw stop;
            }
        };
    }

    public static DefaultTransactionAttribute withoutTransaction() {
        return new DefaultTransactionAttribute(TransactionDefinition.PROPAGATION_NOT_SUPPORTED) {
            @Override
            public boolean rollbackOn(Throwable failure) {
                // TaskletStep uses this rule to decide whether a checked exception ends the step.
                return true;
            }
        };
    }
}
