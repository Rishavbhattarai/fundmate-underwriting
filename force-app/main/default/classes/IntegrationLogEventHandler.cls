/**
 * Stores Integration_Log_Event__e messages as Integration_Log__c records.
 * Upserting on the event UUID makes redelivered events harmless.
 */
public without sharing class IntegrationLogEventHandler {
    public static void handle(List<Integration_Log_Event__e> events) {
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        for (Integration_Log_Event__e e : events) {
            logs.add(
                new Integration_Log__c(
                    Event_Uuid__c = e.EventUuid,
                    Level__c = e.Level__c,
                    Source__c = e.Source__c,
                    Message__c = e.Message__c,
                    Details__c = e.Details__c,
                    Record_Id__c = e.Record_Id__c,
                    Batch_Key__c = e.Batch_Key__c,
                    Http_Status__c = e.Http_Status__c,
                    Limits_Snapshot__c = e.Limits_Snapshot__c
                )
            );
        }
        List<Database.UpsertResult> results = Database.upsert(logs, Integration_Log__c.Event_Uuid__c, false);
        for (Database.UpsertResult r : results) {
            if (!r.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'Integration log insert failed: ' + r.getErrors());
            }
        }
    }
}
