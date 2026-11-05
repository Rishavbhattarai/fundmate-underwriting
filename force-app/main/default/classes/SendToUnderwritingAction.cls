/**
 * "Send to Underwriting" button (and Flow action). Moves the applications to Ready,
 * which runs validation, then starts a send run.
 * Reads in user mode, so users only send records they can see. Writes in system mode
 * because Status is read-only for specialists; only this action and the integration move it.
 */
public with sharing class SendToUnderwritingAction {
    public class Request {
        @InvocableVariable(label='Funding Application Id' required=true)
        public Id applicationId;
    }

    public class Result {
        @InvocableVariable(label='Status')
        public String status;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='Send to Underwriting' description='Validates the applications and starts a send run.' category='FundMate')
    public static List<Result> send(List<Request> requests) {
        Set<Id> ids = new Set<Id>();
        for (Request r : requests) {
            ids.add(r.applicationId);
        }
        List<Funding_Application__c> toReady = new List<Funding_Application__c>();
        for (Funding_Application__c app : [SELECT Id, Status__c FROM Funding_Application__c WHERE Id IN :ids WITH USER_MODE]) {
            if (FundingStatus.SENDABLE.contains(app.Status__c)) {
                toReady.add(new Funding_Application__c(Id = app.Id, Status__c = FundingStatus.READY));
            }
        }
        update toReady; // validation runs in FundingApplicationTrigger

        Map<Id, Funding_Application__c> after = new Map<Id, Funding_Application__c>(
            [SELECT Status__c, Status_Reason__c FROM Funding_Application__c WHERE Id IN :ids WITH USER_MODE]
        );
        List<Result> results = new List<Result>();
        Boolean anyReady = false;
        for (Request r : requests) {
            Funding_Application__c app = after.get(r.applicationId);
            Result res = new Result();
            res.status = app == null ? 'Not found' : app.Status__c;
            res.message = app == null ? 'Application not found or not accessible.'
                : app.Status__c == FundingStatus.READY ? 'Queued for sending.' : app.Status_Reason__c;
            anyReady |= app?.Status__c == FundingStatus.READY;
            results.add(res);
        }
        if (anyReady) {
            System.enqueueJob(new UnderwritingDispatcher());
        }
        return results;
    }
}
