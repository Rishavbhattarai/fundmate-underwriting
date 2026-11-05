/**
 * Retention for Integration_Log__c (GLBA Safeguards: keep data only as long as needed).
 * Deletes logs older than Integration_Setting__mdt.Log_Retention_Days__c (default 90).
 * Platform event messages expire on their own (72-hour retention), so only the stored logs need this.
 *
 * Scheduled daily by scripts/apex/setup-org.apex.
 * Limit: one delete of up to 9,000 rows per run; a backlog clears over a few nights.
 */
public without sharing class IntegrationLogPurge implements Schedulable {
    public static final String JOB_NAME = 'FundMate Log Purge';
    public static final Integer MAX_ROWS = 9000;

    public void execute(SchedulableContext context) {
        run();
    }

    public static Integer run() {
        Datetime cutoff = Datetime.now().addDays(-IntegrationConfig.logRetentionDays());
        List<Integration_Log__c> old = [SELECT Id FROM Integration_Log__c WHERE CreatedDate < :cutoff LIMIT :MAX_ROWS];
        if (!old.isEmpty()) {
            Database.delete(old, false);
        }
        return old.size();
    }

    public static Id scheduleDaily() {
        return System.schedule(JOB_NAME, '0 0 2 * * ?', new IntegrationLogPurge());
    }
}
