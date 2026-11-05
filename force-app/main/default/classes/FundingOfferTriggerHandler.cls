/**
 * Keeps Estimated_APR__c in step with the offer terms.
 */
public with sharing class FundingOfferTriggerHandler {
    public static void beforeSave(List<Funding_Offer__c> offers) {
        for (Funding_Offer__c o : offers) {
            o.Estimated_APR__c = OfferMath.estimateApr(o.Funding_Amount__c, o.Factor_Rate__c, o.Term_Months__c, o.Payment_Frequency__c);
        }
    }
}
