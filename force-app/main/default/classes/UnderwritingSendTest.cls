@IsTest
private class UnderwritingSendTest {
    private static List<Funding_Application__c> readyApps(Integer n) {
        TestDataFactory.settings();
        List<Funding_Application__c> apps = TestDataFactory.completeApplications(n);
        for (Funding_Application__c a : apps) {
            a.Status__c = 'Ready';
        }
        update apps;
        return apps;
    }

    private static Map<String, Integer> countByStatus() {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (AggregateResult r : [SELECT Status__c s, COUNT(Id) c FROM Funding_Application__c GROUP BY Status__c]) {
            counts.put((String) r.get('s'), (Integer) r.get('c'));
        }
        return counts;
    }

    private static Id exceptionsQueue() {
        return [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Integration_Exceptions' LIMIT 1].Id;
    }

    private static void runBatch(TestDataFactory.ApiMock mock) {
        Test.setMock(HttpCalloutMock.class, mock);
        UnderwritingClaimService.ClaimResult claim = UnderwritingClaimService.claim(null);
        Test.startTest();
        Database.executeBatch(new UnderwritingSendBatch(claim.batchKey), 50);
        Test.stopTest();
    }

    @IsTest
    static void acknowledgedApplicationsGetTrackingIds() {
        readyApps(5);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        runBatch(mock);

        Assert.areEqual(1, mock.calls, 'Five applications fit in one callout.');
        Assert.isTrue(mock.lastRequest.getEndpoint().startsWith('callout:Underwriting_API'), 'Must use the Named Credential.');
        Assert.isNotNull(mock.lastRequest.getHeader('Idempotency-Key'), 'Every request carries an idempotency key.');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Map<String, Object> first = (Map<String, Object>) ((List<Object>) body.get('applications'))[0];
        Assert.areEqual('NY', ((Map<String, Object>) first.get('business')).get('state'), 'Business section comes from the field map.');
        Assert.areEqual(1, ((List<Object>) first.get('owners')).size(), 'One qualifying owner.');

        for (Funding_Application__c a : [SELECT Status__c, Tracking_Id__c, Sent_At__c FROM Funding_Application__c]) {
            Assert.areEqual('Acknowledged', a.Status__c, 'All applications should be Acknowledged.');
            Assert.isTrue(a.Tracking_Id__c.startsWith('UW-FA-'), 'Tracking id saved from the API.');
            Assert.isNotNull(a.Sent_At__c, 'Sent time recorded.');
        }
    }

    @IsTest
    static void rejectedStatusIsSaved() {
        readyApps(2);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.status = 'Rejected';
        runBatch(mock);
        Assert.areEqual(2, countByStatus().get('Rejected'), 'Both should be Rejected.');
        Assert.areEqual(2, [SELECT COUNT() FROM Funding_Application__c WHERE OwnerId = :exceptionsQueue()], 'Partner rejections go to Integration Exceptions.');
        Assert.areEqual('Identity not verified.', [SELECT Status_Reason__c FROM Funding_Application__c LIMIT 1].Status_Reason__c, 'API reason kept.');
    }

    @IsTest
    static void rateLimitHonorsRetryAfter() {
        readyApps(3);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.statusCode = 429;
        mock.retryAfter = '120';
        Datetime before = Datetime.now();
        runBatch(mock);

        Set<String> keys = new Set<String>();
        for (Funding_Application__c a : [SELECT Status__c, Retry_Count__c, Next_Retry_At__c, Idempotency_Key__c FROM Funding_Application__c]) {
            keys.add(a.Idempotency_Key__c);
            Assert.isTrue(a.Status__c == 'Queued' || a.Status__c == 'Ready', '429 is transient, never Send Failed: ' + a.Status__c);
            Assert.isTrue(a.Retry_Count__c >= 1, 'Counted as a retry.');
            Long waited = (a.Next_Retry_At__c.getTime() - before.getTime()) / 1000;
            Assert.isTrue(waited >= 119 && waited <= 180, 'Next retry should follow Retry-After (120s), got ' + waited);
        }
        Assert.areEqual(1, keys.size(), 'One Idempotency-Key for the whole batch.');
        Assert.isTrue(mock.calls >= 2, 'The retry job resent the batch.');
        Assert.areEqual(1, new Set<String>(mock.keys).size(), 'Every retry of the batch reused the same Idempotency-Key: ' + mock.keys);
        Assert.isTrue(keys.contains(mock.keys[0]), 'The key sent is the key stored.');
    }

    @IsTest
    static void timeoutIsRetriedWithBackoff() {
        readyApps(1);
        RetryPolicy.fixedRandom = 0.5;
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.throwTimeout = true;
        runBatch(mock);
        Funding_Application__c a = [SELECT Status__c, Retry_Count__c, Status_Reason__c FROM Funding_Application__c LIMIT 1];
        Assert.isTrue(a.Status__c == 'Queued' || a.Status__c == 'Ready', 'Timeouts are retried, never Send Failed: ' + a.Status__c);
        Assert.areEqual(1, new Set<String>(mock.keys).size(), 'The retry after a timeout reused the same Idempotency-Key.');
        Assert.isTrue(a.Status_Reason__c.contains('Read timed out'), a.Status_Reason__c);
    }

    @IsTest
    static void namedCredentialMisconfigurationFailsFast() {
        readyApps(1);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.throwTimeout = true;
        mock.timeoutMessage = 'Field Underwriting_API_Credential.ApiKey does not exist.';
        runBatch(mock);
        Funding_Application__c a = [SELECT Status__c, Status_Reason__c FROM Funding_Application__c LIMIT 1];
        Assert.areEqual('Send Failed', a.Status__c, 'A configuration error is not retried.');
        Assert.isTrue(a.Status_Reason__c.contains('ApiKey'), a.Status_Reason__c);
    }

    @IsTest
    static void clientErrorFailsAndAlerts() {
        readyApps(2);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.statusCode = 400;
        runBatch(mock);
        Assert.areEqual(2, countByStatus().get('Send Failed'), '400 is not retried.');
        Assert.areEqual(2, [SELECT COUNT() FROM Funding_Application__c WHERE OwnerId = :exceptionsQueue()], 'Failed sends go to the Integration Exceptions queue.');
        Assert.isTrue(
            [SELECT Status_Reason__c FROM Funding_Application__c LIMIT 1].Status_Reason__c.contains('HTTP 400'),
            'The API error is shown to the specialist.'
        );
    }

    @IsTest
    static void lastAttemptFails() {
        List<Funding_Application__c> apps = readyApps(1);
        // Max_Attempts__c is 3 in TestDataFactory.settings(); this is attempt 3.
        update new Funding_Application__c(Id = apps[0].Id, Retry_Count__c = 2);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.statusCode = 503;
        runBatch(mock);
        Funding_Application__c a = [SELECT Status__c, Status_Reason__c FROM Funding_Application__c LIMIT 1];
        Assert.areEqual('Send Failed', a.Status__c, 'Out of attempts.');
        Assert.isTrue(a.Status_Reason__c.startsWith('Gave up after 3 attempts'), a.Status_Reason__c);
    }

    @IsTest
    static void missingFromResponseIsRetried() {
        readyApps(2);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.dropFirst = true;
        runBatch(mock);
        Map<String, Integer> counts = countByStatus();
        Assert.areEqual(1, counts.get('Acknowledged'), 'The answered application is saved.');
        Assert.areEqual(1, counts.get('Ready'), 'The missing one is queued for retry.');
    }

    @IsTest
    static void claimIsExclusive() {
        readyApps(3);
        UnderwritingClaimService.ClaimResult first = UnderwritingClaimService.claim(null);
        UnderwritingClaimService.ClaimResult second = UnderwritingClaimService.claim(null);
        Assert.areEqual(3, first.claimed, 'First run claims every Ready application.');
        Assert.areEqual(0, second.claimed, 'A second run must not claim the same applications.');
        Assert.areEqual(3, [SELECT COUNT() FROM Funding_Application__c WHERE Batch_Key__c = :first.batchKey], 'All stamped with the first key.');
    }

    @IsTest
    static void claimsOneThousandWithinLimits() {
        readyApps(1000);
        Test.startTest();
        UnderwritingClaimService.ClaimResult claim = UnderwritingClaimService.claim(null);
        Integer queries = Limits.getQueries();
        Test.stopTest();
        Assert.areEqual(1000, claim.claimed, 'All 1,000 claimed in one transaction.');
        Assert.isTrue(queries <= 5, 'Claim uses a fixed number of queries, used ' + queries);
    }

    @IsTest
    static void retryPausesUntilNextRetryAt() {
        List<Funding_Application__c> apps = readyApps(1);
        update new Funding_Application__c(Id = apps[0].Id, Next_Retry_At__c = Datetime.now().addMinutes(30));
        Assert.areEqual(0, UnderwritingClaimService.claim(null).claimed, 'Not claimable before Next_Retry_At__c.');
    }

    @IsTest
    static void dispatcherStartsBatchAndRespectsKillSwitch() {
        readyApps(2);
        Test.setMock(HttpCalloutMock.class, new TestDataFactory.ApiMock());
        Test.startTest();
        Id jobId = UnderwritingDispatcher.run();
        Test.stopTest();
        Assert.isNotNull(jobId, 'A batch job should start.');
        Assert.areEqual(2, countByStatus().get('Acknowledged'), 'Batch ran and saved results.');

        Integration_Setting__mdt s = TestDataFactory.settings();
        s.Send_Enabled__c = false;
        Assert.isNull(UnderwritingDispatcher.run(), 'Kill switch stops sending.');
    }

    @IsTest
    static void retryJobResendsSameBatchWithSameKey() {
        List<Funding_Application__c> apps = readyApps(3);
        UnderwritingClaimService.ClaimResult claim = UnderwritingClaimService.claim(null);
        Set<Id> ids = new Map<Id, Funding_Application__c>(apps).keySet();
        List<Funding_Application__c> stamped = new List<Funding_Application__c>();
        for (Id i : ids) {
            stamped.add(new Funding_Application__c(Id = i, Idempotency_Key__c = 'key-from-first-attempt', Retry_Count__c = 1));
        }
        update stamped;
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new UnderwritingRetryJob(ids, 'key-from-first-attempt', claim.batchKey));
        Test.stopTest();
        Assert.areEqual(1, mock.calls, 'The three applications are resent together.');
        Assert.areEqual('key-from-first-attempt', mock.lastRequest.getHeader('Idempotency-Key'), 'The retry reuses the batch key.');
        Assert.areEqual(3, countByStatus().get('Acknowledged'), 'The retry saved the results.');
    }

    @IsTest
    static void userResendGetsNewKey() {
        List<Funding_Application__c> apps = readyApps(1);
        update new Funding_Application__c(Id = apps[0].Id, Status__c = 'Send Failed', Idempotency_Key__c = 'old-key');
        update new Funding_Application__c(Id = apps[0].Id, Status__c = 'Ready');
        Assert.isNull([SELECT Idempotency_Key__c FROM Funding_Application__c WHERE Id = :apps[0].Id].Idempotency_Key__c, 'A fresh submission must not reuse a key the partner will ignore.');
    }

    @IsTest
    static void schedulerAndActionEnqueueDispatcher() {
        List<Funding_Application__c> apps = TestDataFactory.completeApplications(1);
        TestDataFactory.settings();
        SendToUnderwritingAction.Request r = new SendToUnderwritingAction.Request();
        r.applicationId = apps[0].Id;
        Test.setMock(HttpCalloutMock.class, new TestDataFactory.ApiMock());
        TestDataFactory.clearSchedules(); // the org's own schedules use the same names; rolled back after the test
        User admin = TestDataFactory.userWith('FundMate_Admin', 'fundmate.admin.test');
        Test.startTest();
        List<SendToUnderwritingAction.Result> results;
        System.runAs(admin) {
            results = SendToUnderwritingAction.send(new List<SendToUnderwritingAction.Request>{ r }); // user mode
        }
        List<Id> jobs = UnderwritingScheduler.scheduleEvery15Minutes();
        Test.stopTest();
        Assert.areEqual('Ready', results[0].status, 'Action moves a Draft to Ready.');
        Assert.areEqual(4, jobs.size(), 'Four schedules cover every 15 minutes.');
        new UnderwritingScheduler().execute(null);
    }

    @IsTest
    static void retryJobSkipsApplicationsThatMovedOn() {
        List<Funding_Application__c> apps = readyApps(2);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        // Nothing is Queued with this key, so the job must not call the API.
        System.enqueueJob(new UnderwritingRetryJob(new Map<Id, Funding_Application__c>(apps).keySet(), 'unused-key', 'batch'));
        Test.stopTest();
        Assert.areEqual(0, mock.calls, 'No callout when the batch has nothing left to send.');
    }

    @IsTest
    static void retryJobFailsAndAlertsOnClientError() {
        List<Funding_Application__c> apps = readyApps(2);
        Set<Id> ids = new Map<Id, Funding_Application__c>(apps).keySet();
        List<Funding_Application__c> queued = new List<Funding_Application__c>();
        for (Id i : ids) {
            queued.add(new Funding_Application__c(Id = i, Status__c = 'Queued', Idempotency_Key__c = 'k-1', Retry_Count__c = 1));
        }
        update queued;
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.statusCode = 400;
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        System.enqueueJob(new UnderwritingRetryJob(ids, 'k-1', 'batch'));
        Test.stopTest();
        Assert.areEqual(2, countByStatus().get('Send Failed'), 'A 400 on retry fails the batch.');
        Assert.areEqual(2, [SELECT COUNT() FROM Funding_Application__c WHERE OwnerId = :exceptionsQueue()], 'And routes it to Integration Exceptions.');
    }

    @IsTest
    static void longRetryAfterIsScheduledWithTheSameKey() {
        readyApps(2);
        TestDataFactory.ApiMock mock = new TestDataFactory.ApiMock();
        mock.statusCode = 503;
        mock.retryAfter = '1800';
        runBatch(mock);
        Set<String> keys = new Set<String>();
        for (Funding_Application__c a : [SELECT Status__c, Next_Retry_At__c, Idempotency_Key__c FROM Funding_Application__c]) {
            Assert.areEqual('Queued', a.Status__c, 'The batch stays together, even for a long wait.');
            Assert.isTrue(a.Next_Retry_At__c > Datetime.now().addMinutes(25), 'Retry-After of 30 minutes is honored.');
            keys.add(a.Idempotency_Key__c);
        }
        Assert.areEqual(1, keys.size(), 'One key for the batch.');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'ScheduledApex' AND ApexClass.Name = 'UnderwritingRetryScheduler'],
            'A wait over 10 minutes uses a one-off scheduled retry, not the shared sweep.'
        );
        UnderwritingRetryJob job = new UnderwritingRetryJob(new Set<Id>(), 'k', 'b');
        Assert.isNotNull(UnderwritingRetryJob.scheduleAt(job, Datetime.now().addHours(2)), 'Scheduling works for any future time.');
    }
}
