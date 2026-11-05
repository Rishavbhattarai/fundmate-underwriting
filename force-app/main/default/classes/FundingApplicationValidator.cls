/**
 * Checks that a Funding Application is complete before it can be sent.
 * Field rules (required, format) come from Payload_Field_Map__mdt and the
 * thresholds from Integration_Setting__mdt, so admins can tune both in Setup.
 */
public inherited sharing class FundingApplicationValidator {
    /** Returns the failure reasons per application. Applications that pass are absent. */
    public static Map<Id, List<String>> validate(Map<Id, FundingApplicationSelector.ApplicationData> data) {
        Map<Id, List<String>> failures = new Map<Id, List<String>>();
        List<Payload_Field_Map__mdt> maps = FundingApplicationSelector.fieldMaps();
        for (Id appId : data.keySet()) {
            List<String> errors = validateOne(data.get(appId), maps);
            if (!errors.isEmpty()) {
                failures.put(appId, errors);
            }
        }
        return failures;
    }

    @TestVisible
    private static List<String> validateOne(FundingApplicationSelector.ApplicationData d, List<Payload_Field_Map__mdt> maps) {
        List<String> errors = new List<String>();
        if (d.business == null) {
            errors.add('No business (Account) is linked.');
            return errors;
        }
        if (d.application.Requested_Amount__c == null || d.application.Requested_Amount__c <= 0) {
            errors.add('Requested Amount must be greater than zero.');
        }

        List<Contact> owners = d.owners();
        if (owners.isEmpty()) {
            errors.add('At least one owner with ' + IntegrationConfig.minOwnerPercentage().stripTrailingZeros().toPlainString() + '% or more ownership is required.');
        }
        Decimal totalOwnership = 0;
        for (Contact c : d.contacts) {
            totalOwnership += c.Ownership_Percentage__c == null ? 0 : c.Ownership_Percentage__c;
        }
        if (totalOwnership > 100) {
            errors.add('Ownership adds up to ' + totalOwnership.stripTrailingZeros().toPlainString() + '%, which is more than 100%.');
        }

        for (Payload_Field_Map__mdt m : maps) {
            if (!FundingApplicationSelector.isValidMap(m)) {
                errors.add('Configuration error: field map ' + m.DeveloperName + ' points to an unknown field.');
                continue;
            }
            if (m.Source_Object__c == FundingApplicationSelector.OBJ_ACCOUNT) {
                checkValue(m, d.business, 'Business', errors);
            } else if (m.Source_Object__c == FundingApplicationSelector.OBJ_APPLICATION) {
                checkValue(m, d.application, 'Application', errors);
            } else if (m.Source_Object__c == FundingApplicationSelector.OBJ_CONTACT) {
                for (Contact owner : owners) {
                    checkValue(m, owner, 'Owner ' + owner.Name, errors);
                }
            }
        }

        errors.addAll(checkStatements(d.statements));
        return errors;
    }

    private static void checkValue(Payload_Field_Map__mdt m, SObject record, String context, List<String> errors) {
        Object value = record.get(m.Source_Field__c);
        String text = value == null ? '' : String.valueOf(value);
        if (String.isBlank(text)) {
            if (m.Required__c) {
                errors.add(context + ': ' + label(m) + ' is required.');
            }
            return;
        }
        if (String.isNotBlank(m.Format_Pattern__c) && !Pattern.matches(m.Format_Pattern__c, text)) {
            errors.add(context + ': ' + (String.isNotBlank(m.Format_Message__c) ? m.Format_Message__c : label(m) + ' has an invalid format.'));
        }
    }

    /** The field's label as users see it (EIN, Date of Birth), not the JSON key. */
    private static String label(Payload_Field_Map__mdt m) {
        Schema.SObjectField f = FundingApplicationSelector.fieldsOf(m.Source_Object__c).get(m.Source_Field__c.toLowerCase());
        return f == null ? m.Json_Key__c : f.getDescribe().getLabel();
    }

    /** Needs the configured number of consecutive months, ending within the allowed age. */
    @TestVisible
    private static List<String> checkStatements(List<Bank_Statement__c> statements) {
        List<String> errors = new List<String>();
        Integer required = IntegrationConfig.minStatements();
        List<Bank_Statement__c> sorted = statements == null ? new List<Bank_Statement__c>() : statements;
        if (sorted.size() < required) {
            errors.add('Needs ' + required + ' monthly bank statements; has ' + sorted.size() + '.');
            return errors;
        }
        // Statements arrive sorted by month ascending. Check the most recent run.
        List<Bank_Statement__c> recent = new List<Bank_Statement__c>();
        for (Integer i = sorted.size() - required; i < sorted.size(); i++) {
            recent.add(sorted[i]);
        }
        for (Integer i = 1; i < recent.size(); i++) {
            if (monthIndex(recent[i].Statement_Month__c) - monthIndex(recent[i - 1].Statement_Month__c) != 1) {
                errors.add('The last ' + required + ' bank statements must be consecutive months.');
                break;
            }
        }
        Date latest = recent[recent.size() - 1].Statement_Month__c;
        Integer age = monthIndex(Date.today()) - monthIndex(latest);
        if (age > IntegrationConfig.maxStatementAgeMonths()) {
            errors.add('The latest bank statement is ' + age + ' months old; the limit is ' + IntegrationConfig.maxStatementAgeMonths() + '.');
        }
        return errors;
    }

    private static Integer monthIndex(Date d) {
        return d.year() * 12 + d.month();
    }
}
