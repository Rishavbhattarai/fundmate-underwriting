/**
 * Runs as a Funding Specialist (Standard User + FundMate_Funding_Specialist) to prove
 * the security model: private applications, Status set only by automation, sending works.
 */
@IsTest
private class SpecialistAccessTest {
    private static User specialist() {
        User u;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            String unique = String.valueOf(Crypto.getRandomInteger()).remove('-');
            u = new User(
                ProfileId = p.Id,
                LastName = 'Specialist',
                Alias = 'spec' + unique.left(4),
                Email = 'specialist' + unique + '@example.com',
                Username = 'specialist' + unique + '@fundmate.test',
                TimeZoneSidKey = 'America/New_York',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            insert u;
            insert new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'FundMate_Funding_Specialist'].Id
            );
        }
        return u;
    }

    @IsTest
    static void specialistCannotSetStatusOrSeeOthersApplications() {
        TestDataFactory.settings();
        User u = specialist();
        Funding_Application__c othersApp = TestDataFactory.completeApplications(1)[0];
        System.runAs(u) {
            Assert.isFalse(Schema.SObjectType.Funding_Application__c.fields.Status__c.isUpdateable(), 'Status is read-only for specialists.');
            Assert.areEqual(Schema.DisplayType.ENCRYPTEDSTRING, Schema.SObjectType.Contact.fields.SSN__c.getType(), 'SSN is classic encrypted.');
            Assert.areEqual(Schema.DisplayType.ENCRYPTEDSTRING, Schema.SObjectType.Contact.fields.Date_of_Birth__c.getType(), 'Date of birth is classic encrypted.');
            Assert.areEqual(0, [SELECT COUNT() FROM Funding_Application__c WHERE Id = :othersApp.Id WITH USER_MODE], 'Applications are private.');
            Boolean blocked = false;
            try {
                update as user new Funding_Application__c(Id = othersApp.Id, Status__c = 'Approved');
            } catch (Exception ex) {
                blocked = true;
            }
            Assert.isTrue(blocked, 'A specialist cannot approve an application by hand.');
        }
    }

    @IsTest
    static void specialistCreatesAndSendsOwnApplication() {
        TestDataFactory.settings();
        User u = specialist();
        Account a = TestDataFactory.business('Blue Harbor Coffee LLC', '12-3456789', 'NY');
        insert a;
        insert TestDataFactory.owner(a.Id, 'Maria', 'Lopez', 100);
        insert TestDataFactory.statements(a.Id, new List<Decimal>{ 52100, 54900, 52750 });
        Test.setMock(HttpCalloutMock.class, new TestDataFactory.ApiMock());
        System.runAs(u) {
            Funding_Application__c app = new Funding_Application__c(Account__c = a.Id, Requested_Amount__c = 75000, Use_of_Funds__c = 'Working Capital');
            insert as user app;
            Funding_Application__c created = [SELECT Snapshot_Statement_Count__c, Average_Monthly_Deposits__c FROM Funding_Application__c WHERE Id = :app.Id WITH USER_MODE];
            Assert.areEqual(3, created.Snapshot_Statement_Count__c, 'Statements snapshotted from the business on create.');
            Assert.areEqual(53250, created.Average_Monthly_Deposits__c, 'Average of the three months.');

            SendToUnderwritingAction.Request r = new SendToUnderwritingAction.Request();
            r.applicationId = app.Id;
            Test.startTest();
            List<SendToUnderwritingAction.Result> results = SendToUnderwritingAction.send(new List<SendToUnderwritingAction.Request>{ r });
            Test.stopTest();
            Assert.areEqual('Ready', results[0].status, 'The specialist can send their own application.');
        }
    }
}
