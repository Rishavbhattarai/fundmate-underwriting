/**
 * One-off scheduled start of an UnderwritingRetryJob, for retries that wait longer than the
 * 10-minute Queueable delay. Keeps the same applications and the same Idempotency-Key.
 * (A class can't be both Queueable and Schedulable, so this small wrapper does the scheduling.)
 * Without sharing: it runs long after the user's request and only passes ids and the key on.
 */
public without sharing class UnderwritingRetryScheduler implements Schedulable {
    public static final String JOB_PREFIX = 'FundMate Retry ';

    private final Set<Id> ids;
    private final String idempotencyKey;
    private final String batchKey;

    public UnderwritingRetryScheduler(Set<Id> ids, String idempotencyKey, String batchKey) {
        this.ids = ids;
        this.idempotencyKey = idempotencyKey;
        this.batchKey = batchKey;
    }

    public void execute(SchedulableContext context) {
        System.enqueueJob(new UnderwritingRetryJob(ids, idempotencyKey, batchKey));
        System.abortJob(context.getTriggerId()); // one-off: remove the schedule once it has fired
    }

    public static Id scheduleAt(Set<Id> ids, String idempotencyKey, String batchKey, Datetime runAt) {
        String cron = runAt.format('s m H d M \'?\' yyyy');
        String name = JOB_PREFIX + String.valueOf(idempotencyKey).left(8) + ' ' + runAt.format('HHmmss') + ' ' + String.valueOf(Crypto.getRandomInteger()).right(4);
        return System.schedule(name, cron, new UnderwritingRetryScheduler(ids, idempotencyKey, batchKey));
    }
}
