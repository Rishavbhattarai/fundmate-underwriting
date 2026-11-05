/**
 * Validates and saves underwriting decisions in bulk. One bad decision never
 * blocks the others: every decision gets its own result.
 *
 *  created    decision and its offers saved, application updated
 *  duplicate  decisionId already processed (or repeated in this request); nothing written
 *  rejected   failed validation or could not be saved; "reason" says why
 *
 * The endpoint has already authenticated the caller and verified the signature,
 * so this class runs without sharing and writes in system mode.
 */
public without sharing class DecisionProcessor {
    public static final String CREATED = 'created';
    public static final String DUPLICATE = 'duplicate';
    public static final String REJECTED = 'rejected';

    public static final String APPROVED = FundingStatus.APPROVED;
    public static final Set<String> DECISIONS = new Set<String>{ FundingStatus.APPROVED, FundingStatus.DECLINED, FundingStatus.NEEDS_MORE_INFO };
    public static final Set<String> FREQUENCIES = new Set<String>{ 'Daily', 'Weekly', 'Monthly' };

    public class Result {
        public String decisionId;
        public String applicationReference;
        public String result;
        public String reason;

        Result(String decisionId, String applicationReference) {
            this.decisionId = decisionId;
            this.applicationReference = applicationReference;
        }
    }

    private class Item {
        Integer index;
        Map<String, Object> raw;
        Result result;
        String decision;
        String reason;
        String trackingId;
        Funding_Application__c app;
        Underwriting_Decision__c record;
        List<Funding_Offer__c> offers = new List<Funding_Offer__c>();
        List<Map<String, Object>> rawOffers = new List<Map<String, Object>>();

        Boolean open() {
            return result.result == null;
        }

        void reject(String why) {
            result.result = REJECTED;
            result.reason = why;
        }
    }

    public static List<Result> process(List<Object> decisions) {
        List<Item> items = new List<Item>();
        for (Integer i = 0; i < decisions.size(); i++) {
            items.add(shapeCheck(i, decisions[i]));
        }

        markDuplicates(items);
        attachApplications(items);
        checkOfferIds(items);
        save(items);

        List<Result> results = new List<Result>();
        for (Item it : items) {
            results.add(it.result);
        }
        return results;
    }

    // ---------- validation ----------

    private static Item shapeCheck(Integer index, Object rawDecision) {
        Item it = new Item();
        it.index = index;
        if (!(rawDecision instanceof Map<String, Object>)) {
            it.result = new Result(null, null);
            it.reject('Decision ' + index + ' is not an object.');
            return it;
        }
        it.raw = (Map<String, Object>) rawDecision;
        it.result = new Result(str(it.raw.get('decisionId')), str(it.raw.get('applicationReference')));

        List<String> errors = new List<String>();
        if (String.isBlank(it.result.decisionId)) {
            errors.add('decisionId is required');
        } else if (it.result.decisionId.length() > 40) {
            errors.add('decisionId is longer than 40 characters');
        }
        if (String.isBlank(it.result.applicationReference)) {
            errors.add('applicationReference is required');
        }
        it.trackingId = str(it.raw.get('trackingId'));
        if (String.isBlank(it.trackingId)) {
            errors.add('trackingId is required');
        }
        it.decision = str(it.raw.get('decision'));
        if (!DECISIONS.contains(it.decision)) {
            errors.add('decision must be one of ' + String.join(new List<String>(DECISIONS), ', '));
        }
        it.reason = str(it.raw.get('decisionReason'));

        Object offersRaw = it.raw.get('offers');
        if (offersRaw != null && !(offersRaw instanceof List<Object>)) {
            errors.add('offers must be an array');
        } else if (offersRaw != null) {
            for (Object o : (List<Object>) offersRaw) {
                if (o instanceof Map<String, Object>) {
                    it.rawOffers.add((Map<String, Object>) o);
                } else {
                    errors.add('each offer must be an object');
                }
            }
        }
        if (it.decision == APPROVED && it.rawOffers.isEmpty()) {
            errors.add('an Approved decision needs at least one offer');
        }
        if (it.decision != null && it.decision != APPROVED && !it.rawOffers.isEmpty()) {
            errors.add('only Approved decisions can include offers');
        }
        Set<String> seenOfferIds = new Set<String>();
        for (Integer i = 0; i < it.rawOffers.size(); i++) {
            errors.addAll(offerErrors(i, it.rawOffers[i], seenOfferIds));
        }

        if (!errors.isEmpty()) {
            it.reject(String.join(errors, '; ') + '.');
        }
        return it;
    }

    private static List<String> offerErrors(Integer i, Map<String, Object> o, Set<String> seen) {
        List<String> errors = new List<String>();
        String prefix = 'offers[' + i + '].';
        String offerId = str(o.get('offerId'));
        if (String.isBlank(offerId)) {
            errors.add(prefix + 'offerId is required');
        } else if (!seen.add(offerId)) {
            errors.add(prefix + 'offerId ' + offerId + ' appears twice');
        }
        Decimal amount = num(o.get('fundingAmount'));
        if (amount == null || amount <= 0) {
            errors.add(prefix + 'fundingAmount must be a positive number');
        }
        Decimal factor = num(o.get('factorRate'));
        if (factor == null || factor < 1 || factor > 5) {
            errors.add(prefix + 'factorRate must be between 1 and 5');
        }
        Decimal term = num(o.get('termMonths'));
        Integer minTerm = IntegrationConfig.minTermMonths();
        Integer maxTerm = IntegrationConfig.maxTermMonths();
        if (term == null || term < minTerm || term > maxTerm || term != term.setScale(0, System.RoundingMode.DOWN)) {
            errors.add(prefix + 'termMonths must be a whole number from ' + minTerm + ' to ' + maxTerm);
        }
        if (!FREQUENCIES.contains(str(o.get('paymentFrequency')))) {
            errors.add(prefix + 'paymentFrequency must be Daily, Weekly or Monthly');
        }
        return errors;
    }

    private static void markDuplicates(List<Item> items) {
        Set<String> ids = new Set<String>();
        for (Item it : items) {
            if (it.open()) {
                ids.add(it.result.decisionId);
            }
        }
        Set<String> existing = new Set<String>();
        for (Underwriting_Decision__c d : [SELECT Decision_Id__c FROM Underwriting_Decision__c WHERE Decision_Id__c IN :ids]) {
            existing.add(d.Decision_Id__c);
        }
        Set<String> seen = new Set<String>();
        for (Item it : items) {
            if (!it.open()) {
                continue;
            }
            if (existing.contains(it.result.decisionId) || !seen.add(it.result.decisionId)) {
                it.result.result = DUPLICATE;
                it.result.reason = 'decisionId ' + it.result.decisionId + ' was already processed.';
            }
        }
    }

    private static void attachApplications(List<Item> items) {
        Set<String> refs = new Set<String>();
        for (Item it : items) {
            if (it.open()) {
                refs.add(it.result.applicationReference);
            }
        }
        // Keyed by reference; a list in case two records share a name (auto-numbers can repeat in test contexts).
        Map<String, List<Funding_Application__c>> byName = new Map<String, List<Funding_Application__c>>();
        for (Funding_Application__c app : [
            SELECT Id, Name, Status__c, Tracking_Id__c
            FROM Funding_Application__c
            WHERE Name IN :refs
        ]) {
            if (!byName.containsKey(app.Name)) {
                byName.put(app.Name, new List<Funding_Application__c>());
            }
            byName.get(app.Name).add(app);
        }
        Set<String> accepting = IntegrationConfig.decisionAcceptingStatuses();
        Set<Id> claimed = new Set<Id>();
        for (Item it : items) {
            if (!it.open()) {
                continue;
            }
            Funding_Application__c app = pick(byName.get(it.result.applicationReference), it.trackingId);
            if (app == null) {
                it.reject('Unknown applicationReference ' + it.result.applicationReference + '.');
            } else if (!accepting.contains(app.Status__c)) {
                it.reject('Application ' + app.Name + ' is ' + app.Status__c + ' and can\'t accept a decision.');
            } else if (app.Tracking_Id__c != null && !app.Tracking_Id__c.equals(it.trackingId)) {
                it.reject('trackingId ' + it.trackingId + ' does not match ' + app.Name + '.');
            } else if (!claimed.add(app.Id)) {
                it.reject('Another decision for ' + app.Name + ' is earlier in this request.');
            } else {
                it.app = app;
            }
        }
    }

    /** The record whose trackingId matches, otherwise the first one (which then fails the tracking check). */
    private static Funding_Application__c pick(List<Funding_Application__c> candidates, String trackingId) {
        if (candidates == null || candidates.isEmpty()) {
            return null;
        }
        for (Funding_Application__c app : candidates) {
            if (app.Tracking_Id__c != null && app.Tracking_Id__c.equals(trackingId)) {
                return app;
            }
        }
        return candidates[0];
    }

    private static void checkOfferIds(List<Item> items) {
        Set<String> incoming = new Set<String>();
        for (Item it : items) {
            if (it.open()) {
                for (Map<String, Object> o : it.rawOffers) {
                    incoming.add(str(o.get('offerId')));
                }
            }
        }
        if (incoming.isEmpty()) {
            return;
        }
        Set<String> taken = new Set<String>();
        for (Funding_Offer__c o : [SELECT Offer_Id__c FROM Funding_Offer__c WHERE Offer_Id__c IN :incoming]) {
            taken.add(o.Offer_Id__c);
        }
        Set<String> inRequest = new Set<String>();
        for (Item it : items) {
            if (!it.open()) {
                continue;
            }
            for (Map<String, Object> o : it.rawOffers) {
                String id = str(o.get('offerId'));
                if (taken.contains(id) || !inRequest.add(id)) {
                    it.reject('offerId ' + id + ' already exists.');
                    break;
                }
            }
        }
    }

    // ---------- writes ----------

    private static void save(List<Item> items) {
        List<Item> ready = new List<Item>();
        List<Underwriting_Decision__c> decisions = new List<Underwriting_Decision__c>();
        for (Item it : items) {
            if (it.open()) {
                it.record = new Underwriting_Decision__c(
                    Funding_Application__c = it.app.Id,
                    Decision_Id__c = it.result.decisionId,
                    Decision__c = it.decision,
                    Decision_Reason__c = it.reason,
                    Tracking_Id__c = it.trackingId,
                    Received_At__c = Datetime.now()
                );
                ready.add(it);
                decisions.add(it.record);
            }
        }
        if (ready.isEmpty()) {
            return;
        }

        List<Database.SaveResult> decisionSaves = Database.insert(decisions, false);
        List<Item> saved = new List<Item>();
        for (Integer i = 0; i < ready.size(); i++) {
            if (decisionSaves[i].isSuccess()) {
                saved.add(ready[i]);
            } else {
                ready[i].reject('Could not save decision: ' + decisionSaves[i].getErrors()[0].getMessage());
            }
        }

        // Offers for each saved decision. If any offer fails, the decision is removed again.
        List<Funding_Offer__c> offers = new List<Funding_Offer__c>();
        List<Item> offerOwner = new List<Item>();
        for (Item it : saved) {
            for (Map<String, Object> o : it.rawOffers) {
                Funding_Offer__c offer = new Funding_Offer__c(
                    Funding_Application__c = it.app.Id,
                    Underwriting_Decision__c = it.record.Id,
                    Offer_Id__c = str(o.get('offerId')),
                    Funding_Amount__c = num(o.get('fundingAmount')),
                    Factor_Rate__c = num(o.get('factorRate')),
                    Term_Months__c = num(o.get('termMonths')),
                    Payment_Frequency__c = str(o.get('paymentFrequency'))
                );
                it.offers.add(offer);
                offers.add(offer);
                offerOwner.add(it);
            }
        }
        Set<Integer> failedOffers = new Set<Integer>();
        if (!offers.isEmpty()) {
            List<Database.SaveResult> offerSaves = Database.insert(offers, false);
            for (Integer i = 0; i < offerSaves.size(); i++) {
                if (!offerSaves[i].isSuccess() && !failedOffers.contains(offerOwner[i].index)) {
                    failedOffers.add(offerOwner[i].index);
                    offerOwner[i].reject('Could not save offer ' + offers[i].Offer_Id__c + ': ' + offerSaves[i].getErrors()[0].getMessage());
                }
            }
        }
        if (!failedOffers.isEmpty()) {
            undo(saved, failedOffers);
        }

        List<Item> done = new List<Item>();
        for (Item it : saved) {
            if (!failedOffers.contains(it.index)) {
                done.add(it);
            }
        }
        if (done.isEmpty()) {
            return;
        }
        supersedeOlderOffers(done);
        updateApplications(done);
    }

    private static void undo(List<Item> saved, Set<Integer> failed) {
        List<Funding_Offer__c> offers = new List<Funding_Offer__c>();
        List<Underwriting_Decision__c> decisions = new List<Underwriting_Decision__c>();
        for (Item it : saved) {
            if (!failed.contains(it.index)) {
                continue;
            }
            for (Funding_Offer__c o : it.offers) {
                if (o.Id != null) {
                    offers.add(o);
                }
            }
            decisions.add(it.record);
        }
        Database.delete(offers, false);
        Database.delete(decisions, false);
    }

    private static void supersedeOlderOffers(List<Item> done) {
        Set<Id> appIds = new Set<Id>();
        Set<Id> newOfferIds = new Set<Id>();
        for (Item it : done) {
            appIds.add(it.app.Id);
            for (Funding_Offer__c o : it.offers) {
                newOfferIds.add(o.Id);
            }
        }
        List<Funding_Offer__c> older = [
            SELECT Id
            FROM Funding_Offer__c
            WHERE Funding_Application__c IN :appIds AND Id NOT IN :newOfferIds AND Superseded__c = FALSE
        ];
        for (Funding_Offer__c o : older) {
            o.Superseded__c = true;
        }
        if (!older.isEmpty()) {
            Database.update(older, false);
        }
    }

    private static void updateApplications(List<Item> done) {
        List<Funding_Application__c> updates = new List<Funding_Application__c>();
        for (Item it : done) {
            updates.add(
                new Funding_Application__c(
                    Id = it.app.Id,
                    Status__c = it.decision,
                    Decision__c = it.decision,
                    Decided_At__c = Datetime.now(),
                    Status_Reason__c = it.reason == null ? null : it.reason.left(255)
                )
            );
        }
        List<Database.SaveResult> saves = Database.update(updates, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (saves[i].isSuccess()) {
                done[i].result.result = CREATED;
            } else {
                done[i].reject('Decision saved but the application could not be updated: ' + saves[i].getErrors()[0].getMessage());
                IntegrationLogger.error('DecisionProcessor', done[i].result.reason, done[i].app.Id);
            }
        }
    }

    // ---------- helpers ----------

    private static String str(Object value) {
        if (value == null) {
            return null;
        }
        return value instanceof String ? ((String) value).trim() : String.valueOf(value);
    }

    private static Decimal num(Object value) {
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        if (value instanceof Long) {
            return Decimal.valueOf((Long) value);
        }
        return null; // JSON.deserializeUntyped only yields Decimal, Integer or Long
    }
}
