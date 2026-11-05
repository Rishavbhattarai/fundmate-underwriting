/**
 * Sends one batch of claimed applications (up to 50) and saves the result on each one.
 * Used by UnderwritingSendBatch for the first attempt and by UnderwritingRetryJob for retries.
 *
 * Idempotency-Key policy (confirmed by FundMate): one key per batch, reused on every retry of that
 * batch; the partner ignores a repeated key for 24 hours.
 *  - The key is stored on each application (Idempotency_Key__c).
 *  - Every retry resends exactly the same applications with the same key: a delayed Queueable for
 *    waits up to 10 minutes, a one-off scheduled job for longer waits.
 *  - A user resend clears the key (FundingApplicationTriggerHandler), so a corrected application
 *    is never mistaken for a repeat.
 *  - An application missing from a 2xx response gets a new key next time, because the partner
 *    may have stored the old one without processing that application.
 *
 * Without sharing on purpose: applications are private and queue-owned; only the claimed
 * records passed in are touched.
 */
public without sharing class UnderwritingBatchSender {
    /** Queueable delays are capped at 10 minutes; longer waits use a one-off scheduled job. */
    public static final Integer MAX_RETRY_JOB_DELAY_SECONDS = 600;

    public Integer sent = 0;
    public Integer acknowledged = 0;
    public Integer rejected = 0;
    public Integer retrying = 0;
    public Integer failed = 0;
    public Map<Id, String> failures = new Map<Id, String>();
    /** Set when this batch should be resent as a unit, with the same key, after delaySeconds. */
    public RetryRequest retry;
    /** Shortest wait among applications returned to the Ready pool (waits over 10 minutes). */
    public Integer shortestPoolRetrySeconds;

    public class RetryRequest {
        public Set<Id> ids;
        public String key;
        public Integer delaySeconds;
    }

    public void send(Set<Id> ids, String batchKey) {
        List<FundingApplicationSelector.ApplicationData> rows = FundingApplicationSelector.load(ids).values();
        if (rows.isEmpty()) {
            return;
        }
        String key = sharedKey(rows);
        UnderwritingApiClient.BatchResponse response = UnderwritingApiClient.sendBatch(UnderwritingPayloadBuilder.build(rows), key);
        sent += rows.size();

        List<Funding_Application__c> updates = new List<Funding_Application__c>();
        if (response.isSuccess()) {
            applyResults(rows, response, updates);
        } else if (response.isTransient()) {
            retryBatch(rows, key, response, updates);
        } else {
            for (FundingApplicationSelector.ApplicationData d : rows) {
                updates.add(fail(d.application, response.errorMessage));
            }
        }
        for (Funding_Application__c u : updates) {
            if (!u.isSet('Idempotency_Key__c')) {
                u.Idempotency_Key__c = key;
            }
        }
        List<Database.SaveResult> saves = Database.update(updates, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (!saves[i].isSuccess()) {
                IntegrationLogger.error('UnderwritingBatchSender', 'Could not save send result: ' + saves[i].getErrors()[0].getMessage(), updates[i].Id);
            }
        }
        IntegrationLogger.add(
            response.isSuccess() ? IntegrationLogger.Level.INFO : IntegrationLogger.Level.WARN,
            'UnderwritingBatchSender',
            'Sent ' + rows.size() + ' applications with Idempotency-Key ' + key + '. ' +
            (response.statusCode != null ? 'HTTP ' + response.statusCode : (response.timedOut ? 'Timeout or network error' : 'Callout error')) +
            (response.batchId == null ? '' : ', API batch ' + response.batchId),
            null,
            batchKey,
            response.statusCode,
            response.isSuccess() ? null : response.errorMessage
        );
    }

    /** Reuse the batch's key when every application already carries the same one; otherwise start a new one. */
    @TestVisible
    private static String sharedKey(List<FundingApplicationSelector.ApplicationData> rows) {
        String first = rows[0].application.Idempotency_Key__c;
        for (FundingApplicationSelector.ApplicationData d : rows) {
            if (String.isBlank(d.application.Idempotency_Key__c) || d.application.Idempotency_Key__c != first) {
                return UUID.randomUUID().toString();
            }
        }
        return first;
    }

    private void applyResults(
        List<FundingApplicationSelector.ApplicationData> rows,
        UnderwritingApiClient.BatchResponse response,
        List<Funding_Application__c> updates
    ) {
        Map<String, UnderwritingApiClient.ResultItem> byReference = new Map<String, UnderwritingApiClient.ResultItem>();
        for (UnderwritingApiClient.ResultItem item : response.results) {
            if (item != null && item.applicationReference != null) {
                byReference.put(item.applicationReference, item);
            }
        }
        for (FundingApplicationSelector.ApplicationData d : rows) {
            UnderwritingApiClient.ResultItem item = byReference.get(d.application.Name);
            if (item == null) {
                // The partner may have stored this key, so a later attempt needs a new one.
                Funding_Application__c u = toPool(d.application, 'Missing from the API response.', null);
                u.Idempotency_Key__c = null;
                updates.add(u);
                continue;
            }
            Funding_Application__c u = new Funding_Application__c(
                Id = d.application.Id,
                Status_Reason__c = item.statusReason == null ? null : item.statusReason.left(255),
                Sent_At__c = Datetime.now(),
                Next_Retry_At__c = null
            );
            if (item.status == FundingStatus.ACKNOWLEDGED) {
                u.Status__c = FundingStatus.ACKNOWLEDGED;
                u.Tracking_Id__c = item.trackingId;
                acknowledged++;
            } else if (item.status == FundingStatus.REJECTED) {
                u.Status__c = FundingStatus.REJECTED;
                rejected++;
            } else {
                updates.add(fail(d.application, 'Unknown status from the API: ' + item.status));
                continue;
            }
            updates.add(u);
        }
    }

    /** Transient failure: resend the same batch with the same key, or fail once attempts run out. */
    private void retryBatch(
        List<FundingApplicationSelector.ApplicationData> rows,
        String key,
        UnderwritingApiClient.BatchResponse response,
        List<Funding_Application__c> updates
    ) {
        Integer attempt = 1;
        for (FundingApplicationSelector.ApplicationData d : rows) {
            attempt = Math.max(attempt, (d.application.Retry_Count__c == null ? 0 : d.application.Retry_Count__c.intValue()) + 1);
        }
        if (attempt >= IntegrationConfig.maxAttempts()) {
            for (FundingApplicationSelector.ApplicationData d : rows) {
                updates.add(fail(d.application, 'Gave up after ' + attempt + ' attempts. Last error: ' + response.errorMessage));
            }
            return;
        }
        Integer delay = RetryPolicy.delaySeconds(attempt, response.retryAfterSeconds);
        retry = new RetryRequest();
        retry.ids = new Set<Id>();
        retry.key = key;
        retry.delaySeconds = delay;
        for (FundingApplicationSelector.ApplicationData d : rows) {
            retrying++;
            updates.add(
                new Funding_Application__c(
                    Id = d.application.Id,
                    Status__c = FundingStatus.QUEUED,
                    Retry_Count__c = attempt,
                    Next_Retry_At__c = Datetime.now().addSeconds(delay),
                    Status_Reason__c = ('Retry ' + attempt + ' in ' + delay + 's: ' + response.errorMessage).left(255)
                )
            );
            retry.ids.add(d.application.Id);
        }
    }

    /** Back to Ready for the sweep, used only for an application missing from a 2xx response (it gets a new key). */
    private Funding_Application__c toPool(Funding_Application__c app, String reason, Integer delaySeconds) {
        Integer attempt = (app.Retry_Count__c == null ? 0 : app.Retry_Count__c.intValue()) + 1;
        Integer delay = delaySeconds != null ? delaySeconds : RetryPolicy.delaySeconds(attempt, null);
        shortestPoolRetrySeconds = shortestPoolRetrySeconds == null ? delay : Math.min(shortestPoolRetrySeconds, delay);
        if (delaySeconds == null) {
            retrying++;
        }
        return new Funding_Application__c(
            Id = app.Id,
            Status__c = FundingStatus.READY,
            Retry_Count__c = attempt,
            Next_Retry_At__c = Datetime.now().addSeconds(delay),
            Status_Reason__c = ('Retry ' + attempt + ' in ' + delay + 's: ' + reason).left(255)
        );
    }

    private Funding_Application__c fail(Funding_Application__c app, String reason) {
        failed++;
        String text = reason == null ? 'Send failed.' : reason.left(255);
        failures.put(app.Id, text);
        return new Funding_Application__c(Id = app.Id, Status__c = FundingStatus.SEND_FAILED, Status_Reason__c = text, Next_Retry_At__c = null);
    }

    /**
     * Queues the batch retry with the same key: a delayed Queueable for waits up to 10 minutes,
     * otherwise (or when the Queueable can't be added) a one-off scheduled job at the retry time.
     */
    public Boolean enqueueRetry(String batchKey) {
        if (retry == null) {
            return false;
        }
        UnderwritingRetryJob job = new UnderwritingRetryJob(retry.ids, retry.key, batchKey);
        if (retry.delaySeconds <= MAX_RETRY_JOB_DELAY_SECONDS && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            try {
                System.enqueueJob(job, Math.min(10, Math.ceil(retry.delaySeconds / 60.0).intValue()));
                return true;
            } catch (AsyncException ex) {
                // Chain depth reached; fall through to a scheduled job, which starts a new chain.
            }
        }
        UnderwritingRetryJob.scheduleAt(job, Datetime.now().addSeconds(Math.max(60, retry.delaySeconds)));
        return true;
    }

    public String summary() {
        return 'Sent ' + sent + ', acknowledged ' + acknowledged + ', rejected ' + rejected + ', retrying ' + retrying + ', failed ' + failed + '.';
    }
}
