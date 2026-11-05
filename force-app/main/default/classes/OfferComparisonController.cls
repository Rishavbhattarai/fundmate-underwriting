/**
 * Data for the offerComparison LWC. Runs in user mode so specialists only see
 * offers and fields their permission sets allow.
 */
public with sharing class OfferComparisonController {
    @AuraEnabled(cacheable=true)
    public static List<Funding_Offer__c> getOffers(Id applicationId) {
        return [
            SELECT
                Id,
                Name,
                Offer_Id__c,
                Funding_Amount__c,
                Factor_Rate__c,
                Term_Months__c,
                Payment_Frequency__c,
                Number_of_Payments__c,
                Payment_Amount__c,
                Total_Payback__c,
                Cost_of_Financing__c,
                Estimated_APR__c,
                Superseded__c,
                Underwriting_Decision__r.Decision_Id__c,
                CreatedDate
            FROM Funding_Offer__c
            WHERE Funding_Application__c = :applicationId
            WITH USER_MODE
            ORDER BY Superseded__c ASC, Estimated_APR__c ASC NULLS LAST, CreatedDate DESC
        ];
    }
}
