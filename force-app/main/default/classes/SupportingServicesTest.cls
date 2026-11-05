@IsTest
private class SupportingServicesTest {
    @IsTest
    static void logEventSurvivesRollback() {
        Savepoint sp = Database.setSavepoint();
        IntegrationLogger.error('Test', 'Something broke for SSN 123-45-6789', null);
        Database.rollback(sp);
        Test.getEventBus().deliver();

        Integration_Log__c log = [SELECT Level__c, Message__c, Limits_Snapshot__c FROM Integration_Log__c LIMIT 1];
        Assert.areEqual('ERROR', log.Level__c, 'The error was stored even though its transaction rolled back.');
        Assert.isFalse(log.Message__c.contains('123-45-6789'), 'SSN must be redacted: ' + log.Message__c);
        Assert.isTrue(log.Limits_Snapshot__c.startsWith('SOQL '), 'Limits snapshot recorded.');
    }

    @IsTest
    static void loggerBuffersInfoAndFlushes() {
        IntegrationLogger.info('Test', 'hello');
        IntegrationLogger.warn('Test', 'careful', null);
        Assert.areEqual(0, IntegrationLogger.publishedCount, 'Info and warn wait for flush.');
        IntegrationLogger.flush();
        Assert.areEqual(2, IntegrationLogger.publishedCount, 'Flush publishes both.');
        try {
            Integer x = 1 / 0;
        } catch (Exception ex) {
            IntegrationLogger.error('Test', ex, null);
        }
        Assert.areEqual(3, IntegrationLogger.publishedCount, 'Errors publish immediately.');
    }

    @IsTest
    static void logPurgeKeepsRecentLogs() {
        TestDataFactory.settings();
        Integration_Log__c oldLog = new Integration_Log__c(Level__c = 'INFO', Source__c = 'Test', Message__c = 'old');
        Integration_Log__c newLog = new Integration_Log__c(Level__c = 'INFO', Source__c = 'Test', Message__c = 'new');
        insert new List<Integration_Log__c>{ oldLog, newLog };
        Test.setCreatedDate(oldLog.Id, Datetime.now().addDays(-120));
        TestDataFactory.clearSchedules();
        Test.startTest();
        Integer removed = IntegrationLogPurge.run();
        Id jobId = IntegrationLogPurge.scheduleDaily();
        Test.stopTest();
        Assert.areEqual(1, removed, 'Only the 120-day-old log is past the 90-day retention.');
        Assert.areEqual('new', [SELECT Message__c FROM Integration_Log__c].Message__c, 'The recent log stays.');
        Assert.isNotNull(jobId, 'Purge can be scheduled.');
        new IntegrationLogPurge().execute(null);
    }

    @IsTest
    static void redactMasksBirthDatesAndBankData() {
        String out = IntegrationLogger.redact('{"dateOfBirth":"1984-03-14","averageMonthlyDeposits":53250.00,"totalNsfCount":2}');
        Assert.isFalse(out.contains('1984-03-14'), out);
        Assert.isFalse(out.contains('53250'), out);
        Assert.isTrue(out.contains('[REDACTED]'), out);
    }

    @IsTest
    static void redactMasksSensitiveValues() {
        String out = IntegrationLogger.redact('ssn 123-45-6789, ein 12-3456789, {"x-api-key":"abc123"}');
        Assert.isFalse(out.contains('123-45-6789'), out);
        Assert.isFalse(out.contains('12-3456789'), out);
        Assert.isFalse(out.contains('abc123'), out);
        Assert.isNull(IntegrationLogger.redact(null), 'Null stays null.');
    }

    @IsTest
    static void offerMath() {
        Assert.areEqual(52, OfferMath.paymentCount('Weekly', 12), '12 months weekly.');
        Assert.areEqual(252, OfferMath.paymentCount('Daily', 12), '21 business days a month.');
        Assert.areEqual(12, OfferMath.paymentCount('Monthly', 12), 'Monthly.');
        Assert.isNull(OfferMath.paymentCount('Hourly', 12), 'Unknown frequency.');
        Decimal apr = OfferMath.estimateApr(75000, 1.32, 12, 'Weekly');
        Assert.isTrue(apr > 57 && apr < 58, 'Weekly 1.32 over 12 months is about 57.5% APR, got ' + apr);
        Assert.areEqual(0, OfferMath.estimateApr(1000, 1.0, 12, 'Monthly'), 'No cost, no APR.');
        Assert.isNull(OfferMath.estimateApr(null, 1.2, 12, 'Weekly'), 'Incomplete inputs.');
    }

    @IsTest
    static void retryPolicy() {
        TestDataFactory.settings();
        RetryPolicy.fixedRandom = 0.5;
        Assert.areEqual(120, RetryPolicy.delaySeconds(1, 120), 'Retry-After wins.');
        Assert.areEqual(3600, RetryPolicy.delaySeconds(1, 999999), 'Retry-After is capped.');
        Assert.areEqual(15, RetryPolicy.delaySeconds(1, null), 'Attempt 1: half of 30s base.');
        Assert.areEqual(60, RetryPolicy.delaySeconds(3, null), 'Attempt 3: half of 120s.');
        Assert.areEqual(1800, RetryPolicy.delaySeconds(20, null), 'Capped at max backoff, then jittered.');
        Assert.areEqual(30, RetryPolicy.parseRetryAfter(' 30 '), 'Seconds form.');
        Assert.isNull(RetryPolicy.parseRetryAfter(''), 'Blank.');
        Assert.isNull(RetryPolicy.parseRetryAfter('soon'), 'Unreadable.');
        Assert.isNull(RetryPolicy.parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), 'HTTP-date falls back to backoff.');
    }

    @IsTest
    static void configDefaults() {
        IntegrationConfig.overrideSetting = new Integration_Setting__mdt(DeveloperName = 'Default');
        Assert.areEqual(50, IntegrationConfig.batchSize(), 'Default batch size.');
        Assert.areEqual(5, IntegrationConfig.maxAttempts(), 'Default attempts.');
        Assert.areEqual('X-Signature', IntegrationConfig.signatureHeader(), 'Default header.');
        Assert.areEqual('callout:Underwriting_API/v1/applications/batch', IntegrationConfig.calloutEndpoint(), 'Default endpoint.');
        Assert.isTrue(IntegrationConfig.decisionAcceptingStatuses().contains('Acknowledged'), 'Default statuses.');
        Assert.areEqual(10000, IntegrationConfig.revenueMinimum(), 'Default revenue minimum.');
        Assert.isFalse(IntegrationConfig.sendEnabled(), 'Unset kill switch means off.');
        IntegrationConfig.overrideSetting = null;
        Assert.isNotNull(IntegrationConfig.settings(), 'The deployed Default record exists.');
    }

    @IsTest
    static void alertsReachOwnerAndAdmins() {
        TestDataFactory.settings();
        List<Funding_Application__c> apps = TestDataFactory.completeApplications(2);
        Group g = [SELECT Id FROM Group WHERE DeveloperName = 'Integration_Admins' LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new GroupMember(GroupId = g.Id, UserOrGroupId = UserInfo.getUserId());
        }
        Test.startTest();
        SendFailureAlertService.notify(new Map<Id, String>{ apps[0].Id => 'HTTP 400', apps[1].Id => 'HTTP 400' });
        Test.stopTest();
        Assert.areEqual(1, SendFailureAlertService.emailsSent, 'Owner and admin are the same user here, so one email lists both apps.');
        SendFailureAlertService.notify(null);
    }

    @IsTest
    static void offerComparisonReturnsOffers() {
        TestDataFactory.settings();
        Funding_Application__c app = TestDataFactory.completeApplications(1)[0];
        insert new List<Funding_Offer__c>{
            new Funding_Offer__c(Funding_Application__c = app.Id, Offer_Id__c = 'A', Funding_Amount__c = 50000, Factor_Rate__c = 1.3, Term_Months__c = 12, Payment_Frequency__c = 'Weekly'),
            new Funding_Offer__c(Funding_Application__c = app.Id, Offer_Id__c = 'B', Funding_Amount__c = 50000, Factor_Rate__c = 1.2, Term_Months__c = 12, Payment_Frequency__c = 'Weekly', Superseded__c = true)
        };
        List<Funding_Offer__c> offers;
        System.runAs(TestDataFactory.userWith('FundMate_Admin', 'fundmate.admin.test')) {
            offers = OfferComparisonController.getOffers(app.Id); // user mode: needs the permission set, not admin rights
        }
        Assert.areEqual(2, offers.size(), 'Both offers returned.');
        Assert.areEqual('A', offers[0].Offer_Id__c, 'Current offers come before superseded ones.');
        Assert.isNotNull(offers[0].Estimated_APR__c, 'APR is calculated on save.');
    }

    @IsTest
    static void payloadBuilderUsesFieldMap() {
        TestDataFactory.settings();
        Funding_Application__c app = TestDataFactory.completeApplications(1)[0];
        String body = UnderwritingPayloadBuilder.build(FundingApplicationSelector.load(new Set<Id>{ app.Id }).values());
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        Map<String, Object> first = (Map<String, Object>) ((List<Object>) parsed.get('applications'))[0];
        Map<String, Object> financials = (Map<String, Object>) first.get('financials');
        Assert.areEqual(3, financials.get('numberOfStatements'), 'Statement count from the roll-up.');
        Assert.areEqual('Working Capital', ((Map<String, Object>) first.get('fundingRequest')).get('useOfFunds'), 'Funding request section.');
        Map<String, Object> owner = (Map<String, Object>) ((List<Object>) first.get('owners'))[0];
        Assert.areEqual('123-45-6789', owner.get('ssn'), 'The API receives the full SSN.');
    }
}
