trigger FundingApplicationTrigger on Funding_Application__c(before insert, after insert, before update) {
    switch on Trigger.operationType {
        when BEFORE_INSERT {
            FundingApplicationTriggerHandler.beforeInsert(Trigger.new);
        }
        when AFTER_INSERT {
            FundingApplicationTriggerHandler.afterInsert(Trigger.new);
        }
        when BEFORE_UPDATE {
            FundingApplicationTriggerHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
        }
    }
}
