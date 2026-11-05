/**
 * Resends one batch after a transient failure: exactly the same applications, with the same
 * Idempotency-Key (FundMate: reuse the key on every retry; the partner ignores a repeat for 24 hours).
 * Enqueued with a delay of up to 10 minutes by UnderwritingBatchSender, or scheduled once for
 * longer waits through UnderwritingRetryScheduler (Schedulable can't call out, so it starts this job).
 */
public without sharing class UnderwritingRetryJob implements Queueable, Database.AllowsCallouts {

    private final Set<Id> ids;
    private final String idempotencyKey;
    private final String batchKey;

    public UnderwritingRetryJob(Set<Id> ids, String idempotencyKey, String batchKey) {
        this.ids = ids;
        this.idempotencyKey = idempotencyKey;
        this.batchKey = batchKey;
    }

    /** Runs this retry once at the given time (through UnderwritingRetryScheduler). */
    public static Id scheduleAt(UnderwritingRetryJob job, Datetime runAt) {
        return UnderwritingRetryScheduler.scheduleAt(job.ids, job.idempotencyKey, job.batchKey, runAt);
    }

    public void execute(QueueableContext context) {
        // Only applications still waiting on this batch; a user may have changed some meanwhile.
        Set<Id> still = new Map<Id, Funding_Application__c>(
            [SELECT Id FROM Funding_Application__c WHERE Id IN :ids AND Status__c = :FundingStatus.QUEUED AND Idempotency_Key__c = :idempotencyKey]
        ).keySet();
        if (still.isEmpty()) {
            return;
        }
        UnderwritingBatchSender sender = new UnderwritingBatchSender();
        sender.send(still, batchKey);
        sender.enqueueRetry(batchKey);
        if (!sender.failures.isEmpty()) {
            SendFailureAlertService.notify(sender.failures);
        }
        if (sender.shortestPoolRetrySeconds != null) {
            UnderwritingDispatcher.scheduleRetry(sender.shortestPoolRetrySeconds);
        }
        IntegrationLogger.limits('UnderwritingRetryJob', 'Retry complete. ' + sender.summary(), batchKey);
        IntegrationLogger.flush();
    }
}
