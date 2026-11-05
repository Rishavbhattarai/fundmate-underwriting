/**
 * Entry point for a send run: claims Ready applications, then starts
 * UnderwritingSendBatch with a scope of Batch_Size__c (50). Started by the
 * scheduler, by the Send to Underwriting action, and by delayed retries.
 */
public with sharing class UnderwritingDispatcher implements Queueable {
    /** Queueable delays are capped at 10 minutes by the platform. */
    public static final Integer MAX_DELAY_MINUTES = 10;

    public void execute(QueueableContext context) {
        run();
    }

    public static Id run() {
        if (!IntegrationConfig.sendEnabled()) {
            IntegrationLogger.info('UnderwritingDispatcher', 'Send_Enabled__c is off; nothing sent.');
            IntegrationLogger.flush();
            return null;
        }
        UnderwritingClaimService.ClaimResult claim = UnderwritingClaimService.claim(null);
        if (claim.claimed == 0) {
            IntegrationLogger.flush();
            return null;
        }
        Id jobId = Database.executeBatch(new UnderwritingSendBatch(claim.batchKey), IntegrationConfig.batchSize());
        IntegrationLogger.limits(
            'UnderwritingDispatcher',
            'Claimed ' + claim.claimed + ' applications; batch job ' + jobId,
            claim.batchKey
        );
        IntegrationLogger.flush();
        return jobId;
    }

    /** Schedules a run after a delay. Waits longer than 10 minutes are left to the scheduled sweep. */
    public static void scheduleRetry(Integer delaySeconds) {
        Integer minutes = Math.ceil(delaySeconds / 60.0).intValue();
        if (minutes > MAX_DELAY_MINUTES) {
            return;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }
        System.enqueueJob(new UnderwritingDispatcher(), Math.max(0, minutes));
    }
}
