@IsTest
private class FundingApplicationValidatorTest {
    @TestSetup
    static void setup() {
        TestDataFactory.settings();
        TestDataFactory.completeApplications(1);
    }

    private static Funding_Application__c reload(Id appId) {
        return [SELECT Status__c, Status_Reason__c, Retry_Count__c FROM Funding_Application__c WHERE Id = :appId];
    }

    @IsTest
    static void completeApplicationBecomesReady() {
        TestDataFactory.settings();
        Funding_Application__c app = [SELECT Id FROM Funding_Application__c LIMIT 1];
        app.Status__c = 'Ready';
        update app;
        Funding_Application__c result = reload(app.Id);
        Assert.areEqual('Ready', result.Status__c, 'A complete application should stay Ready.');
        Assert.isNull(result.Status_Reason__c, 'No reason expected for a valid application.');
    }

    @IsTest
    static void missingEinAndBadStateFail() {
        TestDataFactory.settings();
        Account a = TestDataFactory.business('Cedar and Pine Landscaping', null, 'Calif.');
        insert a;
        insert TestDataFactory.owner(a.Id, 'Tom', 'Becker', 100);
        Funding_Application__c app = new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 600000, Use_of_Funds__c = 'Equipment');
        insert app;
        insert TestDataFactory.statements(a.Id, new List<Decimal>{ 31000, 29500, 33200 });

        app.Status__c = 'Ready';
        update app;

        Funding_Application__c result = reload(app.Id);
        Assert.areEqual('Validation Failed', result.Status__c, 'Cedar and Pine must not be sendable.');
        Assert.isTrue(result.Status_Reason__c.contains('EIN is required'), 'Reason should name the missing EIN: ' + result.Status_Reason__c);
        Assert.isTrue(result.Status_Reason__c.contains('two-letter'), 'Reason should name the bad state: ' + result.Status_Reason__c);
    }

    @IsTest
    static void twoStatementsFail() {
        TestDataFactory.settings();
        Account a = TestDataFactory.business('Lumen Dental Studio PLLC', '45-6789012', 'FL');
        insert a;
        insert TestDataFactory.owner(a.Id, 'Priya', 'Shah', 100);
        Funding_Application__c app = new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 40000, Use_of_Funds__c = 'Equipment');
        insert app;
        insert TestDataFactory.statements(a.Id, new List<Decimal>{ 61000, 58400 });

        app.Status__c = 'Ready';
        update app;

        Funding_Application__c result = reload(app.Id);
        Assert.areEqual('Validation Failed', result.Status__c, 'Two statements are not enough.');
        Assert.isTrue(result.Status_Reason__c.contains('Needs 3 monthly bank statements; has 2'), result.Status_Reason__c);
    }

    @IsTest
    static void insertingAsReadyIsValidatedToo() {
        TestDataFactory.settings();
        Account a = TestDataFactory.business('No Owner Co', '11-1111111', 'TX');
        insert a;
        Funding_Application__c app = new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 10000, Use_of_Funds__c = 'Other', Status__c = 'Ready');
        insert app;

        Funding_Application__c result = reload(app.Id);
        Assert.areEqual('Validation Failed', result.Status__c, 'Insert as Ready must still be validated.');
        Assert.isTrue(result.Status_Reason__c.contains('At least one owner'), result.Status_Reason__c);
        Assert.isTrue(result.Status_Reason__c.contains(' 20% '), 'Percent shown as a plain number, not 2E+1: ' + result.Status_Reason__c);
    }

    @IsTest
    static void ownershipOverOneHundredFails() {
        TestDataFactory.settings();
        Funding_Application__c app = [SELECT Id, Account__c FROM Funding_Application__c LIMIT 1];
        insert TestDataFactory.owner(app.Account__c, 'Second', 'Owner', 30);

        app.Status__c = 'Ready';
        update app;

        Funding_Application__c result = reload(app.Id);
        Assert.areEqual('Validation Failed', result.Status__c, '130% ownership is invalid.');
        Assert.isTrue(result.Status_Reason__c.contains('130%'), 'Total shown as a plain number, not 1.3E+2: ' + result.Status_Reason__c);
        Assert.isTrue(result.Status_Reason__c.contains('more than 100%'), result.Status_Reason__c);
    }

    @IsTest
    static void gapsAndStaleStatementsFail() {
        TestDataFactory.settings();
        Date m = Date.today().toStartOfMonth();
        List<Bank_Statement__c> gap = new List<Bank_Statement__c>{
            new Bank_Statement__c(Statement_Month__c = m.addMonths(-5), Total_Deposits__c = 1),
            new Bank_Statement__c(Statement_Month__c = m.addMonths(-4), Total_Deposits__c = 1),
            new Bank_Statement__c(Statement_Month__c = m.addMonths(-1), Total_Deposits__c = 1)
        };
        List<String> gapErrors = FundingApplicationValidator.checkStatements(gap);
        Assert.areEqual(1, gapErrors.size(), 'Only the gap should be reported: ' + gapErrors);
        Assert.isTrue(gapErrors[0].contains('consecutive'), gapErrors[0]);

        List<Bank_Statement__c> stale = new List<Bank_Statement__c>{
            new Bank_Statement__c(Statement_Month__c = m.addMonths(-9), Total_Deposits__c = 1),
            new Bank_Statement__c(Statement_Month__c = m.addMonths(-8), Total_Deposits__c = 1),
            new Bank_Statement__c(Statement_Month__c = m.addMonths(-7), Total_Deposits__c = 1)
        };
        List<String> staleErrors = FundingApplicationValidator.checkStatements(stale);
        Assert.areEqual(1, staleErrors.size(), 'Only the age should be reported: ' + staleErrors);
        Assert.isTrue(staleErrors[0].contains('months old'), staleErrors[0]);
    }

    @IsTest
    static void badFieldMapIsReported() {
        TestDataFactory.settings();
        FundingApplicationSelector.mapOverride = new List<Payload_Field_Map__mdt>{
            new Payload_Field_Map__mdt(
                DeveloperName = 'bad_map',
                Section__c = 'business',
                Json_Key__c = 'nope',
                Source_Object__c = 'Account',
                Source_Field__c = 'Does_Not_Exist__c',
                Required__c = true,
                Active__c = true,
                Sort_Order__c = 1
            )
        };
        Funding_Application__c app = [SELECT Id FROM Funding_Application__c LIMIT 1];
        Map<Id, List<String>> failures = FundingApplicationValidator.validate(FundingApplicationSelector.load(new Set<Id>{ app.Id }));
        Assert.isTrue(failures.containsKey(app.Id), 'A broken mapping must block sending.');
        Assert.isTrue(String.join(failures.get(app.Id), ' ').contains('Configuration error'), failures.get(app.Id)[0]);
    }

    @IsTest
    static void revenueBelowMinimumIsFlaggedButAllowed() {
        TestDataFactory.settings();
        Account a = TestDataFactory.business('Small Shop LLC', '22-2222222', 'TX');
        insert a;
        insert TestDataFactory.owner(a.Id, 'Sam', 'Small', 100);
        Funding_Application__c app = new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 5000, Use_of_Funds__c = 'Inventory');
        insert app;
        insert TestDataFactory.statements(a.Id, new List<Decimal>{ 4000, 5000, 6000 });

        app.Status__c = 'Ready';
        update app;

        Funding_Application__c result = [SELECT Status__c, Below_Revenue_Minimum__c, Average_Monthly_Deposits__c FROM Funding_Application__c WHERE Id = :app.Id];
        Assert.areEqual('Ready', result.Status__c, 'Low revenue is underwriting\'s call, not a validation failure.');
        Assert.areEqual(5000, result.Average_Monthly_Deposits__c, 'Average should be 15,000 / 3.');
        Assert.isTrue(result.Below_Revenue_Minimum__c, 'Should be flagged for the specialist.');
    }
}
