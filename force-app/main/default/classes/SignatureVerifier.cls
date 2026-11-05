/**
 * Verifies Underwriting API request signatures.
 *
 * signature = hex( HMAC-SHA256( secret, timestamp + "." + rawBody ) )
 *
 * The timestamp (Unix seconds) must be within Signature_Tolerance_Seconds__c of
 * now, so a captured request can't be replayed later. The comparison takes the
 * same time whether the first or the last character differs.
 */
public inherited sharing class SignatureVerifier {
    public enum Outcome {
        VALID,
        NOT_CONFIGURED,
        MISSING_HEADERS,
        STALE_TIMESTAMP,
        INVALID_SIGNATURE
    }

    @TestVisible
    private static Long nowSecondsOverride;

    public static Outcome verify(String rawBody, String timestamp, String signature) {
        String secret = IntegrationConfig.signingSecret();
        if (String.isBlank(secret)) {
            return Outcome.NOT_CONFIGURED;
        }
        if (String.isBlank(timestamp) || String.isBlank(signature) || !timestamp.trim().isNumeric()) {
            return Outcome.MISSING_HEADERS;
        }
        Long sent = Long.valueOf(timestamp.trim());
        Long now = nowSecondsOverride != null ? nowSecondsOverride : Datetime.now().getTime() / 1000;
        if (Math.abs(now - sent) > IntegrationConfig.signatureToleranceSeconds()) {
            return Outcome.STALE_TIMESTAMP;
        }
        String expected = sign(secret, timestamp.trim(), rawBody == null ? '' : rawBody);
        String provided = signature.trim().toLowerCase().removeStart('sha256=');
        return constantTimeEquals(expected, provided) ? Outcome.VALID : Outcome.INVALID_SIGNATURE;
    }

    public static String sign(String secret, String timestamp, String rawBody) {
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf(timestamp + '.' + rawBody), Blob.valueOf(secret));
        return EncodingUtil.convertToHex(mac);
    }

    @TestVisible
    private static Boolean constantTimeEquals(String a, String b) {
        if (a == null || b == null || a.length() != b.length()) {
            return false;
        }
        Integer diff = 0;
        for (Integer i = 0; i < a.length(); i++) {
            diff |= a.charAt(i) ^ b.charAt(i);
        }
        return diff == 0;
    }
}
