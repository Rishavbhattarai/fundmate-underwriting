trigger FundingOfferTrigger on Funding_Offer__c(before insert, before update) {
    FundingOfferTriggerHandler.beforeSave(Trigger.new);
}
