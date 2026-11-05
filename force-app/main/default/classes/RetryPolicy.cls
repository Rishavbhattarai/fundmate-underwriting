/**
 * Decides when to retry a transient failure.
 * Retry-After wins when the API sends it. Otherwise: exponential backoff with
 * full jitter, base * 2^(attempt-1), capped by Max_Backoff_Seconds__c.
 */
public inherited sharing class RetryPolicy {
    @TestVisible
    private static Double fixedRandom;

    /** Seconds to wait before attempt number (attempt + 1). attempt starts at 1. */
    public static Integer delaySeconds(Integer attempt, Integer retryAfterSeconds) {
        Integer cap = IntegrationConfig.maxBackoffSeconds();
        if (retryAfterSeconds != null && retryAfterSeconds >= 0) {
            return Math.min(retryAfterSeconds, cap);
        }
        Integer base = IntegrationConfig.backoffBaseSeconds();
        Long exp = base * Math.pow(2, Math.max(0, attempt - 1)).longValue();
        Long ceiling = Math.min(exp, (Long) cap);
        Double r = fixedRandom != null ? fixedRandom : Math.random();
        // Full jitter keeps retries from many batches from arriving together.
        return Math.max(1, Math.floor(ceiling * r).intValue());
    }

    /** Retry-After in seconds. An HTTP-date form falls back to backoff; parse it if the real API sends dates. */
    public static Integer parseRetryAfter(String header) {
        String value = header == null ? '' : header.trim();
        return value.isNumeric() ? Integer.valueOf(value) : null;
    }
}
