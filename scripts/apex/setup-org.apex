// One-time org setup after deployment. Safe to run again.
//  1. Schedules the 15-minute send sweep (also picks up retries that wait over 10 minutes)
//     and the nightly log purge (Log_Retention_Days__c).
//  2. Adds the running user to the five FundMate queues and the Integration Admins group.
// Run: sf apex run -o <org> -f scripts/apex/setup-org.apex
if ([SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :UnderwritingScheduler.JOB_PREFIX + '%'] == 0) {
    UnderwritingScheduler.scheduleEvery15Minutes();
}
if ([SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = :IntegrationLogPurge.JOB_NAME] == 0) {
    IntegrationLogPurge.scheduleDaily(); // deletes logs past Log_Retention_Days__c
}
Set<String> groups = new Set<String>{ 'Funding_Specialists', 'Senior_Funding_Specialists', 'Document_Collection', 'Declined_Review', 'Integration_Exceptions', 'Integration_Admins' };
Set<Id> already = new Set<Id>();
for (GroupMember m : [SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :UserInfo.getUserId() AND Group.DeveloperName IN :groups]) {
    already.add(m.GroupId);
}
List<GroupMember> adds = new List<GroupMember>();
for (Group g : [SELECT Id FROM Group WHERE DeveloperName IN :groups]) {
    if (!already.contains(g.Id)) {
        adds.add(new GroupMember(GroupId = g.Id, UserOrGroupId = UserInfo.getUserId()));
    }
}
insert adds;
System.debug('SETUP scheduled jobs: ' + [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE :UnderwritingScheduler.JOB_PREFIX + '%']
    + ', memberships added: ' + adds.size() + ' of ' + groups.size());
