// The four sample businesses from the brief, plus Small Shop Bakery (low deposits, which the
// mock Underwriting API rejects): owner, monthly bank statements, then an application (which
// snapshots the statements). Applications start in Draft.
// Run: sf apex run -o <org> -f scripts/apex/seed-sample-data.apex
Date m = Date.today().toStartOfMonth();
List<Account> businesses = new List<Account>{
    new Account(Name = 'Blue Harbor Coffee LLC', EIN__c = '12-3456789', BillingState = 'NY', Business_Start_Date__c = Date.today().addYears(-6)),
    new Account(Name = 'Ridgeview Auto Repair Inc', EIN__c = '98-7654321', BillingState = 'TX', Business_Start_Date__c = Date.today().addYears(-11)),
    new Account(Name = 'Lumen Dental Studio PLLC', EIN__c = '45-6789012', BillingState = 'FL', Business_Start_Date__c = Date.today().addYears(-4)),
    // No EIN and "Calif." on purpose: the brief's sample data includes these gaps.
    new Account(Name = 'Cedar and Pine Landscaping', BillingState = 'Calif.', Business_Start_Date__c = Date.today().addYears(-2)),
    // Not in the brief: passes validation but averages under $10,000 a month, so the partner rejects it.
    new Account(Name = 'Small Shop Bakery LLC', EIN__c = '44-1234567', BillingState = 'NV', Business_Start_Date__c = Date.today().addYears(-2))
};
insert businesses;

insert new List<Contact>{
    new Contact(AccountId = businesses[0].Id, FirstName = 'Maria', LastName = 'Lopez', Date_of_Birth__c = '1984-03-14', SSN__c = '123-45-6789', Ownership_Percentage__c = 100),
    new Contact(AccountId = businesses[1].Id, FirstName = 'Daniel', LastName = 'Okafor', Date_of_Birth__c = '1979-08-02', SSN__c = '234-56-7890', Ownership_Percentage__c = 100),
    new Contact(AccountId = businesses[2].Id, FirstName = 'Priya', LastName = 'Shah', Date_of_Birth__c = '1988-11-23', SSN__c = '345-67-8901', Ownership_Percentage__c = 100),
    new Contact(AccountId = businesses[3].Id, FirstName = 'Tom', LastName = 'Becker', Date_of_Birth__c = '1975-05-09', SSN__c = '456-78-9012', Ownership_Percentage__c = 100),
    new Contact(AccountId = businesses[4].Id, FirstName = 'Ana', LastName = 'Reyes', Date_of_Birth__c = '1990-02-11', SSN__c = '567-12-3456', Ownership_Percentage__c = 100)
};

List<List<Decimal>> deposits = new List<List<Decimal>>{
    new List<Decimal>{ 52100, 54900, 52750 },
    new List<Decimal>{ 140000, 151500, 138200 },
    new List<Decimal>{ 61000, 58400 },
    new List<Decimal>{ 31000, 29500, 33200 },
    new List<Decimal>{ 4200, 5100, 4800 }
};
List<Bank_Statement__c> statements = new List<Bank_Statement__c>();
for (Integer a = 0; a < businesses.size(); a++) {
    List<Decimal> d = deposits[a];
    for (Integer i = 0; i < d.size(); i++) {
        statements.add(new Bank_Statement__c(
            Account__c = businesses[a].Id,
            Statement_Month__c = m.addMonths(-(d.size() - i)),
            Total_Deposits__c = d[i],
            NSF_Count__c = a == 3 ? 2 : 0
        ));
    }
}
insert statements;

List<Funding_Application__c> apps = new List<Funding_Application__c>{
    new Funding_Application__c(Account__c = businesses[0].Id, Requested_Amount__c = 75000, Use_of_Funds__c = 'Working Capital'),
    new Funding_Application__c(Account__c = businesses[1].Id, Requested_Amount__c = 150000, Use_of_Funds__c = 'Equipment'),
    new Funding_Application__c(Account__c = businesses[2].Id, Requested_Amount__c = 40000, Use_of_Funds__c = 'Equipment'),
    new Funding_Application__c(Account__c = businesses[3].Id, Requested_Amount__c = 600000, Use_of_Funds__c = 'Expansion'),
    new Funding_Application__c(Account__c = businesses[4].Id, Requested_Amount__c = 15000, Use_of_Funds__c = 'Inventory')
};
insert apps;
for (Funding_Application__c f : [SELECT Name, Account__r.Name FROM Funding_Application__c WHERE Id IN :apps ORDER BY Name]) {
    System.debug('SEEDED ' + f.Name + ' ' + f.Account__r.Name);
}
