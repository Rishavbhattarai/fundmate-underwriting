// Two Ready applications whose business names make the mock API fail:
// "RATE LIMIT" -> 429 with Retry-After: 60, "SERVER ERROR" -> 503. Both are retried.
Date m = Date.today().toStartOfMonth();
List<Account> accts = new List<Account>{
    new Account(Name = 'RATE LIMIT Demo Bakery', EIN__c = '31-1111111', BillingState = 'NY', Business_Start_Date__c = Date.today().addYears(-3)),
    new Account(Name = 'SERVER ERROR Demo Plumbing', EIN__c = '32-2222222', BillingState = 'TX', Business_Start_Date__c = Date.today().addYears(-3))
};
insert accts;
List<Contact> owners = new List<Contact>();
List<Funding_Application__c> apps = new List<Funding_Application__c>();
for (Account a : accts) {
    owners.add(new Contact(AccountId = a.Id, FirstName = 'Demo', LastName = 'Owner', Date_of_Birth__c = '1982-06-06', SSN__c = '678-90-1234', Ownership_Percentage__c = 100));
    apps.add(new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 50000, Use_of_Funds__c = 'Inventory'));
}
insert owners;
List<Bank_Statement__c> rows = new List<Bank_Statement__c>();
for (Account a : accts) {
    for (Integer k = 3; k >= 1; k--) {
        rows.add(new Bank_Statement__c(Account__c = a.Id, Statement_Month__c = m.addMonths(-k), Total_Deposits__c = 40000, NSF_Count__c = 0));
    }
}
insert rows;
insert apps;
for (Funding_Application__c app : apps) {
    app.Status__c = 'Ready';
}
update apps;
System.debug('SEEDED failure demo: ' + [SELECT Name, Status__c FROM Funding_Application__c WHERE Id IN :apps]);
