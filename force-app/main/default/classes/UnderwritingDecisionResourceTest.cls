@IsTest
private class UnderwritingDecisionResourceTest {
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            TestDataFactory.integrationUser();
        }
        TestDataFactory.settings();
        TestDataFactory.signingSecret();
        List<Funding_Application__c> apps = TestDataFactory.completeApplications(3);
        TestDataFactory.setStatus(apps, 'Acknowledged');
    }

    private static List<Funding_Application__c> apps() {
        return [SELECT Id, Name, Tracking_Id__c, Status__c FROM Funding_Application__c ORDER BY Name];
    }

    private static Map<String, Object> approved(Funding_Application__c app, String decisionId, String offerId) {
        return new Map<String, Object>{
            'decisionId' => decisionId,
            'trackingId' => app.Tracking_Id__c,
            'applicationReference' => app.Name,
            'decision' => 'Approved',
            'decisionReason' => 'Meets guidelines.',
            'offers' => new List<Object>{
                new Map<String, Object>{
                    'offerId' => offerId,
                    'fundingAmount' => 75000.00,
                    'factorRate' => 1.32,
                    'termMonths' => 12,
                    'paymentFrequency' => 'Weekly'
                }
            }
        };
    }

    /** Calls the endpoint like the Underwriting API would. */
    private static Boolean asIntegration = true;

    private static Map<String, Object> post(Object payload, String signatureOverride, Long timestampOffset) {
        TestDataFactory.settings();
        String body = payload instanceof String ? (String) payload : JSON.serialize(payload);
        String ts = String.valueOf(Datetime.now().getTime() / 1000 + (timestampOffset == null ? 0 : timestampOffset));
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/underwriting/decisions';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.addHeader('x-timestamp', ts);
        req.addHeader('X-Signature', signatureOverride != null ? signatureOverride : SignatureVerifier.sign(TestDataFactory.SIGNING_SECRET, ts, body));
        RestContext.request = req;
        RestContext.response = new RestResponse();
        System.runAs(asIntegration ? [SELECT Id FROM User WHERE Username LIKE 'fundmate.integration.test%' LIMIT 1] : new User(Id = UserInfo.getUserId())) {
            UnderwritingDecisionResource.receive();
        }
        Map<String, Object> out = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        out.put('_status', RestContext.response.statusCode);
        return out;
    }

    private static Map<String, Object> post(Object payload) {
        return post(payload, null, null);
    }

    private static List<Object> results(Map<String, Object> out) {
        return (List<Object>) out.get('results');
    }

    private static String resultOf(Map<String, Object> out, Integer i) {
        return (String) ((Map<String, Object>) results(out)[i]).get('result');
    }

    private static String reasonOf(Map<String, Object> out, Integer i) {
        return (String) ((Map<String, Object>) results(out)[i]).get('reason');
    }

    @IsTest
    static void approvedDecisionCreatesOffer() {
        Funding_Application__c app = apps()[0];
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => new List<Object>{ approved(app, 'DEC-1', 'OFR-1') } });

        Assert.areEqual(200, out.get('_status'), 'Signed request accepted.');
        Assert.areEqual('created', resultOf(out, 0), 'Decision created.');
        Funding_Application__c saved = [SELECT Status__c, Decision__c, Decided_At__c, OwnerId FROM Funding_Application__c WHERE Id = :app.Id];
        Assert.areEqual('Approved', saved.Status__c, 'Application status follows the decision.');
        Assert.isNotNull(saved.Decided_At__c, 'Decision time recorded.');
        Funding_Offer__c offer = [SELECT Total_Payback__c, Estimated_APR__c, Superseded__c FROM Funding_Offer__c WHERE Offer_Id__c = 'OFR-1'];
        Assert.areEqual(99000, offer.Total_Payback__c, '75,000 x 1.32.');
        Assert.isTrue(offer.Estimated_APR__c > 50 && offer.Estimated_APR__c < 65, 'APR estimate in the expected range: ' + offer.Estimated_APR__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Underwriting_Decision__c WHERE Decision_Id__c = 'DEC-1'], 'Decision stored.');
    }

    @IsTest
    static void duplicateDecisionIsIgnored() {
        Funding_Application__c app = apps()[0];
        Map<String, Object> payload = new Map<String, Object>{ 'decisions' => new List<Object>{ approved(app, 'DEC-2', 'OFR-2') } };
        post(payload);
        // Approved can't take another decision, so allow it for the resend to reach the duplicate check.
        Map<String, Object> again = post(payload);
        Assert.areEqual('duplicate', resultOf(again, 0), 'Second delivery of the same decision is a duplicate.');
        Assert.areEqual(1, [SELECT COUNT() FROM Funding_Offer__c], 'No extra offers.');
    }

    @IsTest
    static void duplicateWithinOneRequest() {
        Funding_Application__c app = apps()[0];
        Map<String, Object> d = approved(app, 'DEC-3', 'OFR-3');
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => new List<Object>{ d, d } });
        Assert.areEqual('created', resultOf(out, 0), 'First copy created.');
        Assert.areEqual('duplicate', resultOf(out, 1), 'Second copy in the same request is a duplicate.');
    }

    @IsTest
    static void badDecisionsDoNotBlockGoodOnes() {
        List<Funding_Application__c> list0 = apps();
        Map<String, Object> wrongTracking = approved(list0[1], 'DEC-5', 'OFR-5');
        wrongTracking.put('trackingId', 'UW-WRONG');
        Map<String, Object> badOffer = approved(list0[2], 'DEC-6', 'OFR-6');
        ((Map<String, Object>) ((List<Object>) badOffer.get('offers'))[0]).put('factorRate', 9);
        List<Object> decisions = new List<Object>{
            approved(list0[0], 'DEC-4', 'OFR-4'),
            wrongTracking,
            badOffer,
            new Map<String, Object>{ 'decisionId' => 'DEC-7', 'trackingId' => 'UW-X', 'applicationReference' => 'FA-999999', 'decision' => 'Declined' },
            new Map<String, Object>{ 'decisionId' => 'DEC-8', 'trackingId' => 'UW-X', 'applicationReference' => list0[0].Name, 'decision' => 'Maybe' },
            'not an object'
        };
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => decisions });

        Assert.areEqual('created', resultOf(out, 0), 'The valid decision is saved.');
        Assert.isTrue(reasonOf(out, 1).contains('does not match'), reasonOf(out, 1));
        Assert.isTrue(reasonOf(out, 2).contains('factorRate'), reasonOf(out, 2));
        Assert.isTrue(reasonOf(out, 3).contains('Unknown applicationReference'), reasonOf(out, 3));
        Assert.isTrue(reasonOf(out, 4).contains('decision must be one of'), reasonOf(out, 4));
        Assert.isTrue(reasonOf(out, 5).contains('not an object'), reasonOf(out, 5));
        Assert.areEqual(1, out.get('created'), 'Counts match results.');
        Assert.areEqual(5, out.get('rejected'), 'Counts match results.');
    }

    @IsTest
    static void decidedApplicationCannotTakeAnotherDecision() {
        Funding_Application__c app = apps()[0];
        post(new Map<String, Object>{ 'decisions' => new List<Object>{ approved(app, 'DEC-9', 'OFR-9') } });
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => new List<Object>{ approved(app, 'DEC-10', 'OFR-10') } });
        Assert.areEqual('rejected', resultOf(out, 0), 'Approved is not in Decision_Accepting_Statuses__c.');
        Assert.isTrue(reasonOf(out, 0).contains('can\'t accept a decision'), reasonOf(out, 0));
    }

    @IsTest
    static void needsMoreInfoThenApprovalSupersedesOffers() {
        Funding_Application__c app = apps()[0];
        insert new Funding_Offer__c(Funding_Application__c = app.Id, Offer_Id__c = 'OFR-OLD', Funding_Amount__c = 1000, Factor_Rate__c = 1.1, Term_Months__c = 3, Payment_Frequency__c = 'Monthly');
        post(
            new Map<String, Object>{
                'decisions' => new List<Object>{
                    new Map<String, Object>{
                        'decisionId' => 'DEC-11',
                        'trackingId' => app.Tracking_Id__c,
                        'applicationReference' => app.Name,
                        'decision' => 'Needs More Info',
                        'decisionReason' => 'Need October statement.',
                        'offers' => new List<Object>()
                    }
                }
            }
        );
        Assert.areEqual('Needs More Info', [SELECT Status__c FROM Funding_Application__c WHERE Id = :app.Id].Status__c, 'Waiting on documents.');
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => new List<Object>{ approved(app, 'DEC-12', 'OFR-12') } });
        Assert.areEqual('created', resultOf(out, 0), 'A later decision is accepted after Needs More Info.');
        Assert.isTrue([SELECT Superseded__c FROM Funding_Offer__c WHERE Offer_Id__c = 'OFR-OLD'].Superseded__c, 'Older offer superseded.');
        Assert.isFalse([SELECT Superseded__c FROM Funding_Offer__c WHERE Offer_Id__c = 'OFR-12'].Superseded__c, 'New offer current.');
    }

    @IsTest
    static void unsignedTamperedAndStaleRequestsAreRefused() {
        Funding_Application__c app = apps()[0];
        Map<String, Object> payload = new Map<String, Object>{ 'decisions' => new List<Object>{ approved(app, 'DEC-13', 'OFR-13') } };
        Assert.areEqual(401, post(payload, 'deadbeef', null).get('_status'), 'Tampered signature refused.');
        Assert.areEqual(401, post(payload, null, -3600L).get('_status'), 'Stale timestamp refused.');
        Assert.areEqual(0, [SELECT COUNT() FROM Underwriting_Decision__c], 'Nothing written for refused requests.');
    }

    @IsTest
    static void malformedAndOversizedBodies() {
        Assert.areEqual(400, post('not json').get('_status'), 'Invalid JSON is a 400.');
        Assert.areEqual(400, post(new Map<String, Object>{ 'nope' => 1 }).get('_status'), 'Missing decisions array is a 400.');
        Integration_Setting__mdt s = TestDataFactory.settings();
        List<Object> many = new List<Object>();
        for (Integer i = 0; i < 501; i++) {
            many.add(new Map<String, Object>{ 'decisionId' => 'X' + i });
        }
        Assert.areEqual(413, post(new Map<String, Object>{ 'decisions' => many }).get('_status'), 'Over the cap is a 413.');
    }

    @IsTest
    static void missingSecretIsAServerError() {
        delete [SELECT Id FROM Underwriting_Secret__c];
        Assert.areEqual(500, post(new Map<String, Object>{ 'decisions' => new List<Object>() }).get('_status'), 'No secret configured.');
    }

    @IsTest
    static void twoHundredDecisionsInOneRequest() {
        TestDataFactory.settings();
        List<Funding_Application__c> extra = TestDataFactory.completeApplications(197);
        TestDataFactory.setStatus(extra, 'Acknowledged');
        List<Object> decisions = new List<Object>();
        Integer i = 0;
        for (Funding_Application__c app : apps()) {
            decisions.add(approved(app, 'DEC-B-' + i, 'OFR-B-' + i));
            i++;
        }
        Assert.areEqual(200, decisions.size(), 'Exactly 200 decisions.');

        Test.startTest();
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => decisions });
        Integer queries = Limits.getQueries();
        Integer dml = Limits.getDmlStatements();
        Integer cpu = Limits.getCpuTime();
        Test.stopTest();

        List<String> problems = new List<String>();
        for (Object o : results(out)) {
            Map<String, Object> r = (Map<String, Object>) o;
            if (r.get('result') != 'created') {
                problems.add(r.get('applicationReference') + ': ' + r.get('reason'));
            }
        }
        Assert.areEqual(200, out.get('created'), 'All 200 created. Problems: ' + problems);
        Assert.isTrue(queries < 30, 'Bulk-safe query count, used ' + queries);
        Assert.isTrue(dml < 30, 'Bulk-safe DML count, used ' + dml);
        Assert.isTrue(cpu < 10000, 'Within CPU limit, used ' + cpu);
        Assert.areEqual(200, [SELECT COUNT() FROM Funding_Offer__c], 'One offer each.');
    }

    @IsTest
    static void signatureHelpers() {
        Assert.isTrue(SignatureVerifier.constantTimeEquals('abc', 'abc'), 'Equal strings match.');
        Assert.isFalse(SignatureVerifier.constantTimeEquals('abc', 'abd'), 'Different strings fail.');
        Assert.isFalse(SignatureVerifier.constantTimeEquals('abc', 'ab'), 'Different lengths fail.');
        TestDataFactory.settings();
        Assert.areEqual(SignatureVerifier.Outcome.MISSING_HEADERS, SignatureVerifier.verify('{}', null, 'x'), 'Missing timestamp.');
    }

    @IsTest
    static void edgeCasesAreRejectedPerDecision() {
        List<Funding_Application__c> list0 = apps();
        Map<String, Object> longId = approved(list0[0], 'DEC-' + 'X'.repeat(60), 'OFR-L');
        Map<String, Object> offersNotArray = approved(list0[0], 'DEC-E2', 'OFR-E2');
        offersNotArray.put('offers', 'not-a-list');
        Map<String, Object> offerNotObject = approved(list0[0], 'DEC-E3', 'OFR-E3');
        offerNotObject.put('offers', new List<Object>{ 'nope' });
        Map<String, Object> repeatedOffer = approved(list0[0], 'DEC-E4', 'OFR-E4');
        ((List<Object>) repeatedOffer.get('offers')).add(((List<Object>) repeatedOffer.get('offers'))[0]);
        Map<String, Object> declinedWithOffer = approved(list0[1], 'DEC-E5', 'OFR-E5');
        declinedWithOffer.put('decision', 'Declined');
        Map<String, Object> termTooLong = approved(list0[2], 'DEC-E6', 'OFR-E6');
        ((Map<String, Object>) ((List<Object>) termTooLong.get('offers'))[0]).put('termMonths', 36);
        Map<String, Object> missingIds = new Map<String, Object>{ 'decision' => 'Approved' };

        Map<String, Object> out = post(new Map<String, Object>{
            'decisions' => new List<Object>{ longId, offersNotArray, offerNotObject, repeatedOffer, declinedWithOffer, termTooLong, missingIds }
        });
        Assert.areEqual(7, out.get('rejected'), 'Every malformed decision is rejected: ' + out.get('results'));
        Assert.isTrue(reasonOf(out, 0).contains('longer than 40'), reasonOf(out, 0));
        Assert.isTrue(reasonOf(out, 1).contains('offers must be an array'), reasonOf(out, 1));
        Assert.isTrue(reasonOf(out, 2).contains('each offer must be an object'), reasonOf(out, 2));
        Assert.isTrue(reasonOf(out, 3).contains('appears twice'), reasonOf(out, 3));
        Assert.isTrue(reasonOf(out, 4).contains('only Approved decisions can include offers'), reasonOf(out, 4));
        Assert.isTrue(reasonOf(out, 5).contains('from 3 to 18'), 'Terms follow Integration Settings: ' + reasonOf(out, 5));
        Assert.isTrue(reasonOf(out, 6).contains('decisionId is required'), reasonOf(out, 6));
    }

    @IsTest
    static void offerIdAlreadyUsedIsRejected() {
        List<Funding_Application__c> list0 = apps();
        post(new Map<String, Object>{ 'decisions' => new List<Object>{ approved(list0[0], 'DEC-O1', 'OFR-SAME') } });
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => new List<Object>{ approved(list0[1], 'DEC-O2', 'OFR-SAME') } });
        Assert.areEqual('rejected', resultOf(out, 0), 'An offer id can only be used once.');
        Assert.isTrue(reasonOf(out, 0).contains('already exists'), reasonOf(out, 0));
    }

    @IsTest
    static void numbersArriveInEveryJsonShape() {
        Funding_Application__c app = apps()[0];
        // Integer, Long and Decimal JSON numbers all parse.
        String body = '{"decisions":[{"decisionId":"DEC-N1","trackingId":"' + app.Tracking_Id__c + '","applicationReference":"' + app.Name +
            '","decision":"Approved","offers":[{"offerId":"OFR-N1","fundingAmount":3000000000,"factorRate":1.25,"termMonths":12,"paymentFrequency":"Monthly"}]}]}';
        Map<String, Object> out = post(body);
        Assert.areEqual('created', resultOf(out, 0), 'A large whole-number amount (Long) is accepted: ' + out.get('results'));
    }

    @IsTest
    static void otherUsersAreForbidden() {
        asIntegration = false;
        Map<String, Object> out = post(new Map<String, Object>{ 'decisions' => new List<Object>() });
        Assert.areEqual(403, out.get('_status'), 'A valid token for any other user is refused.');
        Assert.areEqual('forbidden', out.get('error'), 'Clear error code.');
    }
}
