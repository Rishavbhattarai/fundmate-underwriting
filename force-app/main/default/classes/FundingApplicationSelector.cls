/**
 * Loads everything needed to validate or send a set of Funding Applications.
 * The fields read from Account, Contact and Funding_Application__c come from
 * Payload_Field_Map__mdt, so adding a field to the request is a metadata change.
 *
 * Runs in system mode: the integration must read encrypted fields (SSN, EIN)
 * regardless of the running user's field access. Callers decide who can run it.
 */
public inherited sharing class FundingApplicationSelector {
    public static final String OBJ_ACCOUNT = 'Account';
    public static final String OBJ_CONTACT = 'Contact';
    public static final String OBJ_APPLICATION = 'Funding_Application__c';

    private static final Set<String> BASE_APPLICATION_FIELDS = new Set<String>{
        'Id',
        'Name',
        'OwnerId',
        'Status__c',
        'Status_Reason__c',
        'Account__c',
        'Requested_Amount__c',
        'Tracking_Id__c',
        'Batch_Key__c',
        'Idempotency_Key__c',
        'Retry_Count__c',
        'Snapshot_Statement_Count__c',
        'Average_Monthly_Deposits__c',
        'Below_Revenue_Minimum__c'
    };

    @TestVisible
    private static List<Payload_Field_Map__mdt> mapOverride;

    public class ApplicationData {
        public Funding_Application__c application;
        public Account business;
        public List<Contact> contacts = new List<Contact>();
        public List<Bank_Statement__c> statements = new List<Bank_Statement__c>();

        /** Contacts at or above the configured ownership threshold. */
        public List<Contact> owners() {
            List<Contact> result = new List<Contact>();
            Decimal threshold = IntegrationConfig.minOwnerPercentage();
            for (Contact c : contacts) {
                if (c.Ownership_Percentage__c != null && c.Ownership_Percentage__c >= threshold) {
                    result.add(c);
                }
            }
            return result;
        }
    }

    /** Active field maps, ordered by section then Sort_Order__c. */
    public static List<Payload_Field_Map__mdt> fieldMaps() {
        List<Payload_Field_Map__mdt> maps = new List<Payload_Field_Map__mdt>();
        List<Payload_Field_Map__mdt> source = mapOverride != null ? mapOverride : Payload_Field_Map__mdt.getAll().values();
        for (Payload_Field_Map__mdt m : source) {
            if (m.Active__c) {
                maps.add(m);
            }
        }
        maps.sort(new SortOrderComparator());
        return maps;
    }

    /** True when the mapped field exists on its object. Invalid maps are reported by the validator. */
    public static Boolean isValidMap(Payload_Field_Map__mdt m) {
        Map<String, Schema.SObjectField> fields = fieldsOf(m.Source_Object__c);
        return fields != null && String.isNotBlank(m.Source_Field__c) && fields.containsKey(m.Source_Field__c.toLowerCase());
    }

    public static Map<Id, ApplicationData> load(Set<Id> applicationIds) {
        Map<Id, ApplicationData> result = new Map<Id, ApplicationData>();
        if (applicationIds == null || applicationIds.isEmpty()) {
            return result;
        }

        Set<String> appFields = new Set<String>(BASE_APPLICATION_FIELDS);
        Set<String> accountFields = new Set<String>{ 'Id' };
        Set<String> contactFields = new Set<String>{ 'Id', 'Name', 'AccountId', 'Ownership_Percentage__c' };
        for (Payload_Field_Map__mdt m : fieldMaps()) {
            if (!isValidMap(m)) {
                continue;
            }
            if (m.Source_Object__c == OBJ_APPLICATION) {
                appFields.add(m.Source_Field__c);
            } else if (m.Source_Object__c == OBJ_ACCOUNT) {
                accountFields.add(m.Source_Field__c);
            } else if (m.Source_Object__c == OBJ_CONTACT) {
                contactFields.add(m.Source_Field__c);
            }
        }

        String appQuery =
            'SELECT ' +
            String.join(new List<String>(appFields), ', ') +
            ' FROM Funding_Application__c WHERE Id IN :ids';
        List<Funding_Application__c> apps = Database.queryWithBinds(
            appQuery,
            new Map<String, Object>{ 'ids' => applicationIds },
            AccessLevel.SYSTEM_MODE
        );

        Set<Id> accountIds = new Set<Id>();
        for (Funding_Application__c app : apps) {
            ApplicationData d = new ApplicationData();
            d.application = app;
            result.put(app.Id, d);
            if (app.Account__c != null) {
                accountIds.add(app.Account__c);
            }
        }
        if (accountIds.isEmpty()) {
            return result;
        }

        Map<Id, Account> accounts = new Map<Id, Account>(
            (List<Account>) Database.queryWithBinds(
                'SELECT ' + String.join(new List<String>(accountFields), ', ') + ' FROM Account WHERE Id IN :ids',
                new Map<String, Object>{ 'ids' => accountIds },
                AccessLevel.SYSTEM_MODE
            )
        );
        Map<Id, List<Contact>> contactsByAccount = new Map<Id, List<Contact>>();
        for (
            Contact c : (List<Contact>) Database.queryWithBinds(
                'SELECT ' +
                    String.join(new List<String>(contactFields), ', ') +
                    ' FROM Contact WHERE AccountId IN :ids ORDER BY Ownership_Percentage__c DESC NULLS LAST',
                new Map<String, Object>{ 'ids' => accountIds },
                AccessLevel.SYSTEM_MODE
            )
        ) {
            if (!contactsByAccount.containsKey(c.AccountId)) {
                contactsByAccount.put(c.AccountId, new List<Contact>());
            }
            contactsByAccount.get(c.AccountId).add(c);
        }

        Map<Id, List<Bank_Statement__c>> statementsByAccount = FinancialSnapshotService.latestStatements(accountIds);
        for (ApplicationData d : result.values()) {
            Id accountId = d.application.Account__c;
            d.business = accounts.get(accountId);
            if (statementsByAccount.containsKey(accountId)) {
                d.statements = statementsByAccount.get(accountId);
            }
            if (contactsByAccount.containsKey(accountId)) {
                d.contacts = contactsByAccount.get(accountId);
            }
        }
        return result;
    }

    private static Map<String, Map<String, Schema.SObjectField>> describeCache = new Map<String, Map<String, Schema.SObjectField>>();

    public static Map<String, Schema.SObjectField> fieldsOf(String objectName) {
        if (String.isBlank(objectName)) {
            return null;
        }
        if (!describeCache.containsKey(objectName)) {
            describeCache.put(objectName, Schema.getGlobalDescribe().get(objectName)?.getDescribe().fields.getMap());
        }
        return describeCache.get(objectName);
    }

    private class SortOrderComparator implements Comparator<Payload_Field_Map__mdt> {
        public Integer compare(Payload_Field_Map__mdt a, Payload_Field_Map__mdt b) {
            Integer bySection = String.valueOf(a.Section__c).compareTo(String.valueOf(b.Section__c));
            if (bySection != 0) {
                return bySection;
            }
            Decimal x = a.Sort_Order__c == null ? 0 : a.Sort_Order__c;
            Decimal y = b.Sort_Order__c == null ? 0 : b.Sort_Order__c;
            return x == y ? 0 : (x < y ? -1 : 1);
        }
    }
}
