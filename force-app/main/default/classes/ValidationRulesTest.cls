@IsTest
private class ValidationRulesTest {
    private static String saveError(SObject record, Boolean isInsert) {
        Database.SaveResult r = isInsert ? Database.insert(record, false) : Database.update(record, false);
        return r.isSuccess() ? null : r.getErrors()[0].getMessage();
    }

    @IsTest
    static void recordRulesBlockBadData() {
        Assert.areEqual('EIN must be in 12-3456789 format.', saveError(new Account(Name = 'X', EIN__c = '123456789'), true), 'EIN format.');
        Account a = TestDataFactory.business('Good Co', '12-3456789', 'NY');
        insert a;
        Contact c = TestDataFactory.owner(a.Id, 'A', 'B', 100);
        c.SSN__c = '123456789';
        Assert.areEqual('SSN must be in 123-45-6789 format.', saveError(c, true), 'SSN format.');
        c.SSN__c = '123-45-6789';
        c.Ownership_Percentage__c = 120;
        Assert.areEqual('Ownership Percentage must be between 0 and 100.', saveError(c, true), 'Ownership range.');
        Assert.isTrue(saveError(new Funding_Application__c(Requested_Amount__c = 1000), true).startsWith('Choose the business'), 'Business required.');
        Assert.areEqual(
            'Requested Amount must be greater than zero.',
            saveError(new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = -1), true),
            'Positive amount.'
        );
    }

    @IsTest
    static void statementsOnePerMonthAndNormalised() {
        TestDataFactory.settings();
        Funding_Application__c app = TestDataFactory.completeApplications(1)[0];
        Bank_Statement__c first = [SELECT Account__c, Statement_Month__c FROM Bank_Statement__c WHERE Account__c = :app.Account__c ORDER BY Statement_Month__c LIMIT 1];
        String err = saveError(
            new Bank_Statement__c(Account__c = first.Account__c, Statement_Month__c = first.Statement_Month__c.addDays(10), Total_Deposits__c = 1),
            true
        );
        Assert.isNotNull(err, 'A second statement for the same month is refused.');
        Assert.areEqual(1, first.Statement_Month__c.day(), 'Months are stored as the first day.');
        Assert.areEqual(
            'Total Deposits can\'t be negative.',
            saveError(new Bank_Statement__c(Account__c = first.Account__c, Statement_Month__c = Date.today().addYears(-2), Total_Deposits__c = -5), true),
            'Negative deposits.'
        );
    }

    @IsTest
    static void applicationLockedWhileWithUnderwriting() {
        TestDataFactory.settings();
        Funding_Application__c app = TestDataFactory.completeApplications(1)[0];
        TestDataFactory.setStatus(new List<Funding_Application__c>{ app }, 'Acknowledged');
        Assert.isTrue(saveError(new Funding_Application__c(Id = app.Id, Requested_Amount__c = 1), false).startsWith('This application is with underwriting'), 'Amount locked.');

        // A new statement on the business doesn't change what underwriting received.
        insert new Bank_Statement__c(Account__c = app.Account__c, Statement_Month__c = Date.today().toStartOfMonth(), Total_Deposits__c = 999999);
        update new Funding_Application__c(Id = app.Id, Status_Reason__c = 'touch');
        Funding_Application__c after = [SELECT Snapshot_Total_Deposits__c FROM Funding_Application__c WHERE Id = :app.Id];
        Assert.areEqual(159750, after.Snapshot_Total_Deposits__c, 'Snapshot stays as sent (52,100 + 54,900 + 52,750).');
        Assert.isNull(saveError(new Funding_Application__c(Id = app.Id, Status__c = 'Approved'), false), 'Automation can still move the status.');
    }

    @IsTest
    static void offerRulesMatchEndpointRules() {
        TestDataFactory.settings();
        Funding_Application__c app = TestDataFactory.completeApplications(1)[0];
        Funding_Offer__c o = new Funding_Offer__c(Funding_Application__c = app.Id, Offer_Id__c = 'V1', Funding_Amount__c = 1000, Factor_Rate__c = 9, Term_Months__c = 12, Payment_Frequency__c = 'Weekly');
        Assert.areEqual('Factor Rate must be between 1 and 5.', saveError(o, true), 'Same range as DecisionProcessor.');
    }
}
