/**
 * Logic behind FundingApplicationTrigger.
 *  - Snapshots the business's latest bank statements onto the application (FinancialSnapshotService).
 *  - When an application moves to Ready it is re-snapshotted and validated. Failures move it to
 *    Validation Failed with the reasons, so it can never be sent incomplete.
 * Without sharing on purpose: validation must see the whole business (owners, statements)
 * whoever presses Send, and the trigger already runs in system context.
 */
public without sharing class FundingApplicationTriggerHandler {

    @TestVisible
    private static Boolean bypass = false;

    public static void beforeInsert(List<Funding_Application__c> records) {
        for (Funding_Application__c app : records) {
            if (String.isBlank(app.Status__c)) {
                app.Status__c = FundingStatus.DRAFT;
            }
        }
        FinancialSnapshotService.apply(records);
    }

    /** Inserted Ready records have no Id in before insert, so they are checked here. */
    public static void afterInsert(List<Funding_Application__c> records) {
        if (bypass) {
            return;
        }
        Set<Id> ready = new Set<Id>();
        for (Funding_Application__c app : records) {
            if (app.Status__c == FundingStatus.READY) {
                ready.add(app.Id);
            }
        }
        if (ready.isEmpty()) {
            return;
        }
        Map<Id, List<String>> failures = FundingApplicationValidator.validate(FundingApplicationSelector.load(ready));
        List<Funding_Application__c> updates = new List<Funding_Application__c>();
        for (Id appId : failures.keySet()) {
            updates.add(
                new Funding_Application__c(
                    Id = appId,
                    Status__c = FundingStatus.VALIDATION_FAILED,
                    Status_Reason__c = reason(failures.get(appId))
                )
            );
        }
        if (!updates.isEmpty()) {
            bypass = true;
            try {
                update updates;
            } finally {
                bypass = false;
            }
        }
    }

    public static void beforeUpdate(List<Funding_Application__c> records, Map<Id, Funding_Application__c> oldMap) {
        if (bypass) {
            return;
        }
        Map<Id, Funding_Application__c> movingToReady = new Map<Id, Funding_Application__c>();
        for (Funding_Application__c app : records) {
            String previous = oldMap.get(app.Id).Status__c;
            // Queued -> Ready is the send pipeline scheduling a retry; it keeps its retry counters.
            if (app.Status__c == FundingStatus.READY && previous != FundingStatus.READY && previous != FundingStatus.QUEUED) {
                movingToReady.put(app.Id, app);
            }
        }
        if (movingToReady.isEmpty()) {
            return;
        }
        // Re-snapshot on submit so the latest statements are what gets validated and sent.
        FinancialSnapshotService.apply(movingToReady.values());
        Map<Id, FundingApplicationSelector.ApplicationData> data = FundingApplicationSelector.load(movingToReady.keySet());
        // Validate the values being saved, not the ones already in the database.
        for (FundingApplicationSelector.ApplicationData d : data.values()) {
            overlay(d.application, movingToReady.get(d.application.Id));
        }
        Map<Id, List<String>> failures = FundingApplicationValidator.validate(data);
        for (Funding_Application__c app : movingToReady.values()) {
            if (failures.containsKey(app.Id)) {
                app.Status__c = FundingStatus.VALIDATION_FAILED;
                app.Status_Reason__c = reason(failures.get(app.Id));
            } else {
                app.Status_Reason__c = null;
                app.Retry_Count__c = 0;
                app.Next_Retry_At__c = null;
                // A fresh submission is a new batch for the partner, so it gets a new Idempotency-Key.
                app.Idempotency_Key__c = null;
            }
        }
    }

    private static void overlay(Funding_Application__c target, Funding_Application__c source) {
        Map<String, Object> populated = source.getPopulatedFieldsAsMap();
        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Funding_Application__c.fields.getMap();
        for (String name : populated.keySet()) {
            Schema.SObjectField f = fields.get(name.toLowerCase());
            if (f != null && f.getDescribe().isUpdateable()) {
                target.put(name, populated.get(name));
            }
        }
    }

    public static String reason(List<String> errors) {
        String text = String.join(errors, '\n');
        return text.length() > 255 ? text.left(252) + '...' : text;
    }
}
