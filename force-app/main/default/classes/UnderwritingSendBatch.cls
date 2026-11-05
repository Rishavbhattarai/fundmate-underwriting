/**
 * Sends one claimed run to the Underwriting API, Batch_Size__c applications per callout.
 * Each execute is its own transaction with its own governor limits, so 1,000 applications
 * become 20 executes with one callout each. UnderwritingBatchSender does the per-batch work;
 * a transient failure is retried as the same batch with the same Idempotency-Key.
 *
 * Without sharing on purpose: applications are private and queue-owned, and the run may be
 * started by any specialist. Only claimed records (by batch key) are touched.
 */
public without sharing class UnderwritingSendBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private final String batchKey;
    private Integer sent = 0;
    private Integer acknowledged = 0;
    private Integer rejected = 0;
    private Integer retrying = 0;
    private Integer failed = 0;
    private Integer shortestPoolRetrySeconds;
    private Map<Id, String> failures = new Map<Id, String>();

    public UnderwritingSendBatch(String batchKey) {
        this.batchKey = batchKey;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator(
            [
                SELECT Id
                FROM Funding_Application__c
                WHERE Status__c = :FundingStatus.QUEUED AND Batch_Key__c = :batchKey
                ORDER BY CreatedDate ASC
            ]
        );
    }

    public void execute(Database.BatchableContext bc, List<Funding_Application__c> scope) {
        UnderwritingBatchSender sender = new UnderwritingBatchSender();
        sender.send(new Map<Id, Funding_Application__c>(scope).keySet(), batchKey);
        sender.enqueueRetry(batchKey); // one Queueable per execute is within the async limit
        sent += sender.sent;
        acknowledged += sender.acknowledged;
        rejected += sender.rejected;
        retrying += sender.retrying;
        failed += sender.failed;
        failures.putAll(sender.failures);
        if (sender.shortestPoolRetrySeconds != null) {
            shortestPoolRetrySeconds = shortestPoolRetrySeconds == null
                ? sender.shortestPoolRetrySeconds
                : Math.min(shortestPoolRetrySeconds, sender.shortestPoolRetrySeconds);
        }
        IntegrationLogger.flush();
    }

    public void finish(Database.BatchableContext bc) {
        IntegrationLogger.limits(
            'UnderwritingSendBatch',
            'Run complete. Sent ' + sent + ', acknowledged ' + acknowledged + ', rejected ' + rejected +
            ', retrying ' + retrying + ', failed ' + failed + '.',
            batchKey
        );
        if (!failures.isEmpty()) {
            SendFailureAlertService.notify(failures);
        }
        if (shortestPoolRetrySeconds != null) {
            UnderwritingDispatcher.scheduleRetry(shortestPoolRetrySeconds);
        }
        IntegrationLogger.flush();
    }
}
