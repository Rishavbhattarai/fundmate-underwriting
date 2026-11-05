/**
 * Claims Ready applications for one send run.
 *
 * The claim runs in its own transaction before any callout. Rows are locked with
 * FOR UPDATE, re-read under the lock, and only those still Ready move to Queued
 * with this run's batch key. A second run that starts at the same time waits on
 * the lock, then finds the rows already Queued and skips them, so an application
 * is never sent twice.
 */
public without sharing class UnderwritingClaimService {

    /** Upper bound per run; stays well inside the 10,000 DML row limit. */
    public static final Integer MAX_CLAIM = 5000;

    public class ClaimResult {
        public String batchKey;
        public Integer claimed = 0;
    }

    public static ClaimResult claim(Integer maxRecords) {
        ClaimResult result = new ClaimResult();
        result.batchKey = UUID.randomUUID().toString();
        Integer cap = Math.min(maxRecords == null ? MAX_CLAIM : maxRecords, MAX_CLAIM);
        Datetime now = Datetime.now();

        List<Funding_Application__c> candidates = [
            SELECT Id
            FROM Funding_Application__c
            WHERE Status__c = :FundingStatus.READY AND (Next_Retry_At__c = NULL OR Next_Retry_At__c <= :now)
            LIMIT :cap
            FOR UPDATE
        ];
        if (candidates.isEmpty()) {
            return result;
        }

        // Re-read under the lock: another run may have claimed these rows while we waited.
        List<Funding_Application__c> locked = [
            SELECT Id, Status__c
            FROM Funding_Application__c
            WHERE Id IN :candidates
            FOR UPDATE
        ];
        List<Funding_Application__c> toClaim = new List<Funding_Application__c>();
        for (Funding_Application__c app : locked) {
            if (app.Status__c == FundingStatus.READY) {
                toClaim.add(new Funding_Application__c(Id = app.Id, Status__c = FundingStatus.QUEUED, Batch_Key__c = result.batchKey));
            }
        }
        if (toClaim.isEmpty()) {
            return result;
        }
        List<Database.SaveResult> saves = Database.update(toClaim, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (saves[i].isSuccess()) {
                result.claimed++;
            } else {
                IntegrationLogger.error('UnderwritingClaimService', 'Claim failed: ' + saves[i].getErrors()[0].getMessage(), toClaim[i].Id);
            }
        }
        return result;
    }
}
