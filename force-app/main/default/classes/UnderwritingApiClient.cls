/**
 * Calls the Underwriting API batch endpoint through the Underwriting_API Named
 * Credential. The X-Api-Key header is added by the Named Credential from the
 * External Credential, so no URL or secret appears in code.
 */
public inherited sharing class UnderwritingApiClient {
    public class BatchResponse {
        public Integer statusCode;
        public String body;
        public Integer retryAfterSeconds;
        public Boolean timedOut = false;
        public String errorMessage;
        public List<ResultItem> results = new List<ResultItem>();
        public String batchId;

        public Boolean isSuccess() {
            return statusCode != null && statusCode >= 200 && statusCode < 300;
        }

        /** 429, 5xx and timeouts can succeed later. Other 4xx will not. */
        public Boolean isTransient() {
            return timedOut || statusCode == 408 || statusCode == 429 || (statusCode != null && statusCode >= 500);
        }
    }

    public class ResultItem {
        public String applicationReference;
        public String status;
        public String statusReason;
        public String trackingId;
    }

    private class ResponseBody {
        public String batchId;
        public List<ResultItem> results;
    }

    public static BatchResponse sendBatch(String body, String idempotencyKey) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(IntegrationConfig.calloutEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Idempotency-Key', idempotencyKey);
        req.setTimeout(IntegrationConfig.calloutTimeoutMs());
        req.setBody(body);

        BatchResponse out = new BatchResponse();
        try {
            HttpResponse res = new Http().send(req);
            out.statusCode = res.getStatusCode();
            out.body = res.getBody();
            out.retryAfterSeconds = RetryPolicy.parseRetryAfter(res.getHeader('Retry-After'));
            if (out.isSuccess()) {
                parse(out);
            } else {
                out.errorMessage = 'HTTP ' + out.statusCode + ': ' + (out.body == null ? '' : out.body.left(500));
            }
        } catch (CalloutException ex) {
            // Timeouts and network failures can succeed later; a misconfigured Named
            // Credential (missing key, bad URL) won't, so it fails fast and alerts.
            out.errorMessage = ex.getMessage();
            out.timedOut = ex.getMessage() != null &&
                Pattern.compile('(?i)timed out|timeout|connection|unreachable|unknown ?host').matcher(ex.getMessage()).find();
        }
        return out;
    }

    private static void parse(BatchResponse out) {
        try {
            ResponseBody parsed = (ResponseBody) JSON.deserialize(out.body, ResponseBody.class);
            out.batchId = parsed.batchId;
            if (parsed.results != null) {
                out.results = parsed.results;
            }
        } catch (JSONException ex) {
            // A 2xx with an unreadable body is treated like a failed call so nothing is lost.
            out.statusCode = 502;
            out.errorMessage = 'Unreadable response body: ' + ex.getMessage();
        }
    }
}
