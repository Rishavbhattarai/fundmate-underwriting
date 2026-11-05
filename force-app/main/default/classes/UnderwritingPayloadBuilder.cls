/**
 * Builds the POST /v1/applications/batch request body.
 * Keys and source fields come from Payload_Field_Map__mdt, grouped by section:
 *
 * { "applications": [ { "applicationReference": "FA-000123",
 *     "business": {...}, "owners": [ {...} ], "financials": {...}, "fundingRequest": {...} } ] }
 */
public inherited sharing class UnderwritingPayloadBuilder {
    public static final String SECTION_BUSINESS = 'business';
    public static final String SECTION_OWNERS = 'owners';
    public static final String SECTION_FINANCIALS = 'financials';
    public static final String SECTION_FUNDING = 'fundingRequest';

    public static String build(List<FundingApplicationSelector.ApplicationData> applications) {
        List<Payload_Field_Map__mdt> maps = FundingApplicationSelector.fieldMaps();
        List<Object> items = new List<Object>();
        for (FundingApplicationSelector.ApplicationData d : applications) {
            items.add(buildOne(d, maps));
        }
        return JSON.serialize(new Map<String, Object>{ 'applications' => items }, true);
    }

    @TestVisible
    private static Map<String, Object> buildOne(FundingApplicationSelector.ApplicationData d, List<Payload_Field_Map__mdt> maps) {
        Map<String, Object> business = new Map<String, Object>();
        Map<String, Object> financials = new Map<String, Object>();
        Map<String, Object> funding = new Map<String, Object>();
        List<Payload_Field_Map__mdt> ownerMaps = new List<Payload_Field_Map__mdt>();

        for (Payload_Field_Map__mdt m : maps) {
            if (!FundingApplicationSelector.isValidMap(m)) {
                continue;
            }
            if (m.Section__c == SECTION_OWNERS) {
                ownerMaps.add(m);
                continue;
            }
            SObject source = m.Source_Object__c == FundingApplicationSelector.OBJ_ACCOUNT ? (SObject) d.business : (SObject) d.application;
            Object value = source == null ? null : source.get(m.Source_Field__c);
            if (m.Section__c == SECTION_BUSINESS) {
                business.put(m.Json_Key__c, value);
            } else if (m.Section__c == SECTION_FINANCIALS) {
                financials.put(m.Json_Key__c, value);
            } else if (m.Section__c == SECTION_FUNDING) {
                funding.put(m.Json_Key__c, value);
            }
        }

        List<Object> owners = new List<Object>();
        for (Contact c : d.owners()) {
            Map<String, Object> owner = new Map<String, Object>();
            for (Payload_Field_Map__mdt m : ownerMaps) {
                owner.put(m.Json_Key__c, c.get(m.Source_Field__c));
            }
            owners.add(owner);
        }

        return new Map<String, Object>{
            'applicationReference' => d.application.Name,
            SECTION_BUSINESS => business,
            SECTION_OWNERS => owners,
            SECTION_FINANCIALS => financials,
            SECTION_FUNDING => funding
        };
    }
}
