/**
 * Copies the business's latest bank statements onto the application: total deposits,
 * statement count, NSF count and the month range. Taken when the application is created
 * and again when it is submitted, so underwriting sees exactly what was sent.
 * "Latest" means the most recent Min_Statements__c months (FundMate uses the last 3).
 */
public inherited sharing class FinancialSnapshotService {
    /** Latest statements per business, oldest first. */
    public static Map<Id, List<Bank_Statement__c>> latestStatements(Set<Id> accountIds) {
        Map<Id, List<Bank_Statement__c>> result = new Map<Id, List<Bank_Statement__c>>();
        Integer keep = IntegrationConfig.minStatements();
        for (Bank_Statement__c s : [
            SELECT Account__c, Statement_Month__c, Total_Deposits__c, NSF_Count__c
            FROM Bank_Statement__c
            WHERE Account__c IN :accountIds
            WITH SYSTEM_MODE
            ORDER BY Account__c, Statement_Month__c DESC
        ]) {
            if (!result.containsKey(s.Account__c)) {
                result.put(s.Account__c, new List<Bank_Statement__c>());
            }
            List<Bank_Statement__c> rows = result.get(s.Account__c);
            if (rows.size() < keep) {
                rows.add(s);
            }
        }
        // The query returns newest first; callers expect oldest first.
        for (Id accountId : result.keySet()) {
            List<Bank_Statement__c> newestFirst = result.get(accountId);
            List<Bank_Statement__c> oldestFirst = new List<Bank_Statement__c>();
            for (Integer i = newestFirst.size() - 1; i >= 0; i--) {
                oldestFirst.add(newestFirst[i]);
            }
            result.put(accountId, oldestFirst);
        }
        return result;
    }

    /** Sets the snapshot fields in memory; callers save them (before-save trigger context). */
    public static void apply(List<Funding_Application__c> apps) {
        Set<Id> accountIds = new Set<Id>();
        for (Funding_Application__c app : apps) {
            if (app.Account__c != null) {
                accountIds.add(app.Account__c);
            }
        }
        Map<Id, List<Bank_Statement__c>> byAccount = latestStatements(accountIds);
        for (Funding_Application__c app : apps) {
            List<Bank_Statement__c> rows = byAccount.containsKey(app.Account__c) ? byAccount.get(app.Account__c) : new List<Bank_Statement__c>();
            Decimal deposits = 0;
            Decimal nsf = 0;
            for (Bank_Statement__c s : rows) {
                deposits += s.Total_Deposits__c == null ? 0 : s.Total_Deposits__c;
                nsf += s.NSF_Count__c == null ? 0 : s.NSF_Count__c;
            }
            app.Snapshot_Statement_Count__c = rows.size();
            app.Snapshot_Total_Deposits__c = deposits;
            app.Snapshot_NSF_Count__c = nsf;
            app.Snapshot_First_Month__c = rows.isEmpty() ? null : rows[0].Statement_Month__c;
            app.Snapshot_Last_Month__c = rows.isEmpty() ? null : rows[rows.size() - 1].Statement_Month__c;
        }
    }
}
