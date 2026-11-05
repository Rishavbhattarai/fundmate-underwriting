/**
 * POST /services/apexrest/underwriting/decisions
 *
 * Receives decisions from the Underwriting API. The caller authenticates with
 * OAuth (client credentials, integration user) and must hold the
 * FundMate_Post_Underwriting_Decisions custom permission; every request must also
 * carry a valid HMAC signature over the raw body. Unsigned or stale requests get 401 and
 * nothing is written.
 *
 * Responses:
 *  200  processed; "results" has one entry per decision (created, duplicate or rejected)
 *  400  body is not JSON or has no "decisions" array
 *  401  signature missing, stale or invalid
 *  403  the caller is not the integration user (no FundMate_Post_Underwriting_Decisions)
 *  413  more decisions than Max_Decisions_Per_Request__c
 *  500  unexpected error (logged; nothing partial is left behind)
 */
@RestResource(urlMapping='/underwriting/decisions')
global with sharing class UnderwritingDecisionResource {
    private static final String SOURCE = 'UnderwritingDecisionResource';
    public static final String PERMISSION = 'FundMate_Post_Underwriting_Decisions';

    @HttpPost
    global static void receive() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String rawBody = req.requestBody == null ? '' : req.requestBody.toString();

        // Only the integration user (FundMate_Integration permission set) may post decisions.
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            IntegrationLogger.warn(SOURCE, 'Rejected request from ' + UserInfo.getUserName() + ': missing ' + PERMISSION, null);
            IntegrationLogger.flush();
            respond(res, 403, error('forbidden', 'This user is not allowed to post underwriting decisions.'));
            return;
        }

        SignatureVerifier.Outcome outcome = SignatureVerifier.verify(
            rawBody,
            header(req, IntegrationConfig.timestampHeader()),
            header(req, IntegrationConfig.signatureHeader())
        );
        if (outcome != SignatureVerifier.Outcome.VALID) {
            IntegrationLogger.warn(SOURCE, 'Rejected request: ' + outcome.name() + ' from ' + req.remoteAddress, null);
            IntegrationLogger.flush();
            respond(res, outcome == SignatureVerifier.Outcome.NOT_CONFIGURED ? 500 : 401, error(
                outcome == SignatureVerifier.Outcome.NOT_CONFIGURED ? 'server_not_configured' : 'invalid_signature',
                outcome == SignatureVerifier.Outcome.NOT_CONFIGURED ? 'Signing secret is not configured.' : 'Request signature could not be verified.'
            ));
            return;
        }

        List<Object> decisions;
        try {
            Object parsed = JSON.deserializeUntyped(rawBody);
            Object rawList = parsed instanceof Map<String, Object> ? ((Map<String, Object>) parsed).get('decisions') : null;
            decisions = rawList instanceof List<Object> ? (List<Object>) rawList : null;
        } catch (JSONException ex) {
            decisions = null;
        }
        if (decisions == null) {
            respond(res, 400, error('invalid_body', 'Body must be JSON with a "decisions" array.'));
            return;
        }
        if (decisions.size() > IntegrationConfig.maxDecisionsPerRequest()) {
            respond(res, 413, error('too_many_decisions', 'At most ' + IntegrationConfig.maxDecisionsPerRequest() + ' decisions per request.'));
            return;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            List<DecisionProcessor.Result> results = DecisionProcessor.process(decisions);
            Map<String, Integer> counts = new Map<String, Integer>{ 'created' => 0, 'duplicate' => 0, 'rejected' => 0 };
            for (DecisionProcessor.Result r : results) {
                counts.put(r.result, counts.get(r.result) + 1);
            }
            IntegrationLogger.limits(
                SOURCE,
                'Received ' + decisions.size() + ' decisions: ' + counts.get('created') + ' created, ' +
                counts.get('duplicate') + ' duplicate, ' + counts.get('rejected') + ' rejected.',
                null
            );
            IntegrationLogger.flush();
            respond(res, 200, new Map<String, Object>{
                'received' => decisions.size(),
                'created' => counts.get('created'),
                'duplicate' => counts.get('duplicate'),
                'rejected' => counts.get('rejected'),
                'results' => results
            });
        } catch (Exception ex) {
            Database.rollback(sp);
            // The log event is Publish Immediately, so it survives the rollback above.
            IntegrationLogger.error(SOURCE, ex, null);
            respond(res, 500, error('server_error', 'Unexpected error. The request was not applied; it is safe to retry.'));
        }
    }

    private static String header(RestRequest req, String name) {
        if (req.headers == null) {
            return null;
        }
        for (String key : req.headers.keySet()) {
            if (key != null && key.equalsIgnoreCase(name)) {
                return req.headers.get(key);
            }
        }
        return null;
    }

    private static Map<String, Object> error(String code, String message) {
        return new Map<String, Object>{ 'error' => code, 'message' => message };
    }

    private static void respond(RestResponse res, Integer status, Object body) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(body, true));
    }
}
