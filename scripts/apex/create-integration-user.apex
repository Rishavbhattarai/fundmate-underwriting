// Creates the API-only user the Underwriting API authenticates as (OAuth client credentials).
// Uses a Salesforce Integration license, the "Minimum Access - API Only Integrations" profile,
// the Salesforce API Integration permission set license and the FundMate_Integration permission set.
// No welcome email is sent. Safe to run again.
String username = 'fundmate.integration.' + UserInfo.getOrganizationId().left(15).toLowerCase() + '@example.com';
List<User> existing = [SELECT Id FROM User WHERE Username = :username];
User u;
if (existing.isEmpty()) {
    u = new User(
        Username = username,
        LastName = 'Underwriting Integration',
        FirstName = 'FundMate',
        Alias = 'fmint',
        Email = [SELECT Email FROM User WHERE Id = :UserInfo.getUserId()].Email,
        ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - API Only Integrations' LIMIT 1].Id,
        TimeZoneSidKey = 'America/New_York',
        LocaleSidKey = 'en_US',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US'
    );
    Database.DMLOptions opts = new Database.DMLOptions();
    opts.EmailHeader.triggerUserEmail = false;
    u.setOptions(opts);
    insert u;
} else {
    u = existing[0];
}
PermissionSetLicense psl = [SELECT Id FROM PermissionSetLicense WHERE DeveloperName = 'SalesforceAPIIntegrationPsl' LIMIT 1];
if ([SELECT COUNT() FROM PermissionSetLicenseAssign WHERE AssigneeId = :u.Id AND PermissionSetLicenseId = :psl.Id] == 0) {
    insert new PermissionSetLicenseAssign(AssigneeId = u.Id, PermissionSetLicenseId = psl.Id);
}
Id ps = [SELECT Id FROM PermissionSet WHERE Name = 'FundMate_Integration' LIMIT 1].Id;
if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :u.Id AND PermissionSetId = :ps] == 0) {
    insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps);
}
System.debug('INTEGRATION_USER ' + username + ' ' + u.Id);
