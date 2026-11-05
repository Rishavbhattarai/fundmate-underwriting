/**
 * Builds FundMate test data. Mirrors the brief's sample businesses.
 */
@IsTest
public class TestDataFactory {
    public static final String SIGNING_SECRET = 'test-signing-secret';

    /** Deterministic settings so tests don't depend on what an admin set in the org. */
    public static Integration_Setting__mdt settings() {
        Integration_Setting__mdt s = new Integration_Setting__mdt(
            DeveloperName = 'Default',
            Named_Credential__c = 'Underwriting_API',
            Batch_Path__c = '/v1/applications/batch',
            Batch_Size__c = 50,
            Max_Attempts__c = 3,
            Backoff_Base_Seconds__c = 30,
            Max_Backoff_Seconds__c = 3600,
            Callout_Timeout_Ms__c = 20000,
            Signature_Tolerance_Seconds__c = 300,
            Signature_Header__c = 'X-Signature',
            Timestamp_Header__c = 'X-Timestamp',
            Min_Statements__c = 3,
            Max_Statement_Age_Months__c = 3,
            Min_Owner_Percentage__c = 20,
            Revenue_Minimum__c = 10000,
            Send_Enabled__c = true,
            Alert_Group__c = 'Integration_Admins',
            Decision_Accepting_Statuses__c = 'Acknowledged,Needs More Info',
            Max_Decisions_Per_Request__c = 500,
            Log_Retention_Days__c = 90,
            Min_Term_Months__c = 3,
            Max_Term_Months__c = 18
        );
        IntegrationConfig.overrideSetting = s;
        return s;
    }

    /** A Standard User with FundMate_Integration, standing in for the API-only integration user. */
    public static User integrationUser() {
        return userWith('FundMate_Integration', 'fundmate.integration.test');
    }

    /**
     * A Standard User holding one FundMate permission set. Created as the running user to avoid
     * mixed-DML errors. Use it for code that runs in user mode, so tests don't rely on admin access.
     */
    public static User userWith(String permissionSet, String usernamePrefix) {
        String unique = String.valueOf(Crypto.getRandomInteger()).remove('-');
        User u = new User(
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
            LastName = 'FundMate Test',
            Alias = 'fmt' + unique.left(5),
            Email = 'fundmate' + unique + '@example.com',
            Username = usernamePrefix + unique + '@example.com',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSet].Id);
        }
        return u;
    }

    /** Removes FundMate schedules so a test can create them under the same names. Rolled back with the test. */
    public static void clearSchedules() {
        for (CronTrigger c : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'FundMate%']) {
            System.abortJob(c.Id);
        }
    }

    public static void signingSecret() {
        insert new Underwriting_Secret__c(SetupOwnerId = UserInfo.getOrganizationId(), Signing_Secret__c = SIGNING_SECRET);
    }

    public static Account business(String name, String ein, String state) {
        return new Account(Name = name, EIN__c = ein, BillingState = state, Business_Start_Date__c = Date.today().addYears(-3));
    }

    public static Contact owner(Id accountId, String first, String last, Decimal pct) {
        return new Contact(
            AccountId = accountId,
            FirstName = first,
            LastName = last,
            Date_of_Birth__c = '1985-04-02',
            SSN__c = '123-45-6789',
            Ownership_Percentage__c = pct
        );
    }

    /** Monthly statements for a business, ending last month, oldest first. */
    public static List<Bank_Statement__c> statements(Id accountId, List<Decimal> deposits) {
        List<Bank_Statement__c> rows = new List<Bank_Statement__c>();
        Date month = Date.today().toStartOfMonth();
        for (Integer i = 0; i < deposits.size(); i++) {
            rows.add(
                new Bank_Statement__c(
                    Account__c = accountId,
                    Statement_Month__c = month.addMonths(-(deposits.size() - i)),
                    Total_Deposits__c = deposits[i],
                    NSF_Count__c = 0
                )
            );
        }
        return rows;
    }

    /** Creates n complete, valid applications for one business (with 3 months of statements), left in Draft. */
    public static List<Funding_Application__c> completeApplications(Integer n) {
        Account a = business('Blue Harbor Coffee LLC', '12-3456789', 'NY');
        insert a;
        insert owner(a.Id, 'Maria', 'Lopez', 100);
        insert statements(a.Id, new List<Decimal>{ 52100, 54900, 52750 });
        List<Funding_Application__c> apps = new List<Funding_Application__c>();
        for (Integer i = 0; i < n; i++) {
            apps.add(new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 75000, Use_of_Funds__c = 'Working Capital'));
        }
        insert apps; // FinancialSnapshotService copies the statements onto each application
        return apps;
    }

    /** Moves applications straight to a status without running Ready validation. */
    public static void setStatus(List<Funding_Application__c> apps, String status) {
        List<Funding_Application__c> updates = new List<Funding_Application__c>();
        for (Integer i = 0; i < apps.size(); i++) {
            Funding_Application__c u = new Funding_Application__c(Id = apps[i].Id, Status__c = status);
            if (status == 'Acknowledged') {
                u.Tracking_Id__c = 'UW-T-' + apps[i].Id;
            }
            updates.add(u);
        }
        update updates;
    }

    /** Fake Underwriting API: answers every application with the given status. */
    public class ApiMock implements HttpCalloutMock {
        public Integer statusCode = 200;
        public String status = 'Acknowledged';
        public String retryAfter;
        public Boolean throwTimeout = false;
        public String timeoutMessage = 'Read timed out';
        public Boolean dropFirst = false;
        public Integer calls = 0;
        public HttpRequest lastRequest;
        public List<String> keys = new List<String>();

        public HttpResponse respond(HttpRequest req) {
            calls++;
            lastRequest = req;
            keys.add(req.getHeader('Idempotency-Key'));
            if (throwTimeout) {
                throw new CalloutException(timeoutMessage);
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            if (retryAfter != null) {
                res.setHeader('Retry-After', retryAfter);
            }
            if (statusCode != 200) {
                res.setBody('{"error":"simulated"}');
                return res;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            List<Object> results = new List<Object>();
            Integer i = 0;
            for (Object o : (List<Object>) body.get('applications')) {
                Map<String, Object> app = (Map<String, Object>) o;
                if (dropFirst && i++ == 0) {
                    continue;
                }
                String ref = (String) app.get('applicationReference');
                results.add(
                    new Map<String, Object>{
                        'applicationReference' => ref,
                        'status' => status,
                        'statusReason' => status == 'Acknowledged' ? 'Queued for review.' : 'Identity not verified.',
                        'trackingId' => status == 'Acknowledged' ? 'UW-' + ref : null
                    }
                );
            }
            res.setBody(JSON.serialize(new Map<String, Object>{ 'batchId' => 'b-test-0001', 'results' => results }));
            return res;
        }
    }
}
