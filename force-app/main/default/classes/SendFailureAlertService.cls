/**
 * Tells people when applications fail to send: the record owner (or, when the owner is a
 * queue such as Integration Exceptions, its members) and every user in the group named in
 * Integration_Setting__mdt.Alert_Group__c. Each recipient gets
 * one in-app notification and one email per run, listing their failed applications.
 */
public without sharing class SendFailureAlertService {
    public static final String NOTIFICATION_TYPE = 'FundMate_Send_Failure';
    private static final Integer MAX_LISTED = 20;

    @TestVisible
    private static Integer emailsSent = 0;
    @TestVisible
    private static Integer notificationsSent = 0;

    public static void notify(Map<Id, String> failures) {
        if (failures == null || failures.isEmpty()) {
            return;
        }
        try {
            send(failures);
        } catch (Exception ex) {
            // An alert problem must never undo the send results that were saved.
            IntegrationLogger.error('SendFailureAlertService', ex, null);
        }
    }

    private static void send(Map<Id, String> failures) {
        Map<Id, Funding_Application__c> apps = new Map<Id, Funding_Application__c>(
            [SELECT Id, Name, OwnerId, Account__r.Name FROM Funding_Application__c WHERE Id IN :failures.keySet()]
        );
        Set<Id> adminIds = groupUserIds(IntegrationConfig.alertGroup());
        // Failed applications route to the Integration Exceptions queue; its members hear about them too.
        Set<Id> queueIds = new Set<Id>();
        for (Funding_Application__c app : apps.values()) {
            if (app.OwnerId.getSObjectType() == Group.SObjectType) {
                queueIds.add(app.OwnerId);
            }
        }
        Map<Id, Set<Id>> queueMembers = new Map<Id, Set<Id>>();
        for (GroupMember m : [SELECT GroupId, UserOrGroupId FROM GroupMember WHERE GroupId IN :queueIds]) {
            if (m.UserOrGroupId.getSObjectType() == User.SObjectType) {
                if (!queueMembers.containsKey(m.GroupId)) {
                    queueMembers.put(m.GroupId, new Set<Id>());
                }
                queueMembers.get(m.GroupId).add(m.UserOrGroupId);
            }
        }

        // recipient -> applications to tell them about
        Map<Id, List<Funding_Application__c>> byRecipient = new Map<Id, List<Funding_Application__c>>();
        for (Funding_Application__c app : apps.values()) {
            Set<Id> recipients = new Set<Id>(adminIds);
            if (app.OwnerId.getSObjectType() == User.SObjectType) {
                recipients.add(app.OwnerId);
            } else if (queueMembers.containsKey(app.OwnerId)) {
                recipients.addAll(queueMembers.get(app.OwnerId));
            }
            for (Id userId : recipients) {
                if (!byRecipient.containsKey(userId)) {
                    byRecipient.put(userId, new List<Funding_Application__c>());
                }
                byRecipient.get(userId).add(app);
            }
        }
        if (byRecipient.isEmpty()) {
            IntegrationLogger.warn('SendFailureAlertService', failures.size() + ' applications failed to send, but no alert recipients were found.', null);
            return;
        }

        Id typeId = notificationTypeId();
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (Id userId : byRecipient.keySet()) {
            List<Funding_Application__c> userApps = byRecipient.get(userId);
            String title = userApps.size() == 1
                ? userApps[0].Name + ' failed to send to underwriting'
                : userApps.size() + ' funding applications failed to send to underwriting';
            String body = describe(userApps, failures);

            if (typeId != null) {
                Messaging.CustomNotification n = new Messaging.CustomNotification();
                n.setNotificationTypeId(typeId);
                n.setTitle(title);
                n.setBody(body.left(750));
                n.setTargetId(userApps[0].Id);
                n.send(new Set<String>{ userId });
                notificationsSent++;
            }

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setTargetObjectId(userId);
            email.setSaveAsActivity(false);
            email.setSubject(title);
            email.setPlainTextBody(body + '\n\nOpen the applications in Salesforce, fix the cause, and use Send to Underwriting to retry.');
            emails.add(email);
        }
        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails, false);
            emailsSent += emails.size();
        }
    }

    private static String describe(List<Funding_Application__c> apps, Map<Id, String> failures) {
        List<String> lines = new List<String>();
        for (Integer i = 0; i < Math.min(apps.size(), MAX_LISTED); i++) {
            Funding_Application__c a = apps[i];
            lines.add(a.Name + ' (' + (a.Account__r == null ? 'no business' : a.Account__r.Name) + '): ' + failures.get(a.Id));
        }
        if (apps.size() > MAX_LISTED) {
            lines.add('...and ' + (apps.size() - MAX_LISTED) + ' more.');
        }
        return String.join(lines, '\n');
    }

    private static Set<Id> groupUserIds(String groupDeveloperName) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(groupDeveloperName)) {
            return ids;
        }
        for (GroupMember m : [SELECT UserOrGroupId FROM GroupMember WHERE Group.DeveloperName = :groupDeveloperName]) {
            if (m.UserOrGroupId.getSObjectType() == User.SObjectType) {
                ids.add(m.UserOrGroupId);
            }
        }
        return ids;
    }

    private static Id notificationTypeId() {
        List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIFICATION_TYPE LIMIT 1];
        return types.isEmpty() ? null : types[0].Id;
    }
}
