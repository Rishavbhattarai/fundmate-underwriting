// Deletes FundMate demo data: applications (with decisions and offers), their businesses
// (with owners and bank statements), and integration logs. Metadata and settings stay.
List<Funding_Application__c> apps = [SELECT Id, Account__c FROM Funding_Application__c LIMIT 5000];
Set<Id> accountIds = new Set<Id>();
for (Funding_Application__c a : apps) {
    accountIds.add(a.Account__c);
}
delete apps;
delete [SELECT Id FROM Contact WHERE AccountId IN :accountIds];
delete [SELECT Id FROM Account WHERE Id IN :accountIds];
delete [SELECT Id FROM Integration_Log__c LIMIT 9000];
System.debug('RESET removed ' + apps.size() + ' applications.');
