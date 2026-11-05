// Creates 250 complete applications and sets them to Ready (validated by the trigger).
// Run 4 times for 1,000: for i in 1 2 3 4; do sf apex run -o <org> -f scripts/apex/seed-scale.apex; done
Integer n = 250;
Account a = new Account(Name = 'Scale Test Business ' + Datetime.now().getTime(), EIN__c = '77-1234567', BillingState = 'NJ', Business_Start_Date__c = Date.today().addYears(-5));
insert a;
insert new Contact(AccountId = a.Id, FirstName = 'Scale', LastName = 'Owner', Date_of_Birth__c = '1980-01-01', SSN__c = '567-89-0123', Ownership_Percentage__c = 100);
Date m = Date.today().toStartOfMonth();
List<Bank_Statement__c> rows = new List<Bank_Statement__c>();
for (Integer k = 3; k >= 1; k--) {
    rows.add(new Bank_Statement__c(Account__c = a.Id, Statement_Month__c = m.addMonths(-k), Total_Deposits__c = 45000 + k * 1000, NSF_Count__c = 0));
}
insert rows;
List<Funding_Application__c> apps = new List<Funding_Application__c>();
for (Integer i = 0; i < n; i++) {
    apps.add(new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 25000 + Math.mod(i, 20) * 25000, Use_of_Funds__c = 'Working Capital'));
}
insert apps;
for (Funding_Application__c app : apps) {
    app.Status__c = 'Ready';
}
update apps;
System.debug('SEEDED ' + [SELECT COUNT() FROM Funding_Application__c WHERE Status__c = 'Ready'] + ' Ready applications in the org. ' + IntegrationLogger.limitsSnapshot());
