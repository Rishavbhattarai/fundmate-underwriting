/**
 * Reads runtime settings for the Underwriting integration from Custom Metadata.
 * Every value an admin may want to tune lives in Integration_Setting__mdt.Default,
 * so behaviour changes in Setup without a deployment.
 */
public inherited sharing class IntegrationConfig {
    public static final String DEFAULT_RECORD = 'Default';

    @TestVisible
    private static Integration_Setting__mdt overrideSetting;

    private static Integration_Setting__mdt cached;

    public static Integration_Setting__mdt settings() {
        if (overrideSetting != null) {
            return overrideSetting;
        }
        if (cached == null) {
            cached = Integration_Setting__mdt.getInstance(DEFAULT_RECORD);
            if (cached == null) {
                throw new ConfigException('Integration_Setting__mdt record "' + DEFAULT_RECORD + '" is missing.');
            }
        }
        return cached;
    }

    public static Integer batchSize() {
        // The API accepts at most 50 applications per request.
        return Math.min(50, Math.max(1, intOr(settings().Batch_Size__c, 50)));
    }

    public static Integer maxAttempts() {
        return Math.max(1, intOr(settings().Max_Attempts__c, 5));
    }

    public static Integer backoffBaseSeconds() {
        return Math.max(1, intOr(settings().Backoff_Base_Seconds__c, 30));
    }

    public static Integer maxBackoffSeconds() {
        return Math.max(backoffBaseSeconds(), intOr(settings().Max_Backoff_Seconds__c, 3600));
    }

    public static Integer calloutTimeoutMs() {
        // Apex allows 1 to 120 seconds per callout.
        return Math.min(120000, Math.max(1000, intOr(settings().Callout_Timeout_Ms__c, 20000)));
    }

    public static Integer signatureToleranceSeconds() {
        return Math.max(1, intOr(settings().Signature_Tolerance_Seconds__c, 300));
    }

    public static String signatureHeader() {
        return String.isBlank(settings().Signature_Header__c) ? 'X-Signature' : settings().Signature_Header__c;
    }

    public static String timestampHeader() {
        return String.isBlank(settings().Timestamp_Header__c) ? 'X-Timestamp' : settings().Timestamp_Header__c;
    }

    public static String calloutEndpoint() {
        String nc = String.isBlank(settings().Named_Credential__c) ? 'Underwriting_API' : settings().Named_Credential__c;
        String path = String.isBlank(settings().Batch_Path__c) ? '/v1/applications/batch' : settings().Batch_Path__c;
        return 'callout:' + nc + path;
    }

    public static Integer minStatements() {
        return Math.max(1, intOr(settings().Min_Statements__c, 3));
    }

    public static Integer maxStatementAgeMonths() {
        return Math.max(1, intOr(settings().Max_Statement_Age_Months__c, 3));
    }

    public static Decimal minOwnerPercentage() {
        return settings().Min_Owner_Percentage__c == null ? 20 : settings().Min_Owner_Percentage__c;
    }

    public static Decimal revenueMinimum() {
        return settings().Revenue_Minimum__c == null ? 10000 : settings().Revenue_Minimum__c;
    }

    public static Boolean sendEnabled() {
        return settings().Send_Enabled__c == true;
    }

    public static String alertGroup() {
        return settings().Alert_Group__c;
    }

    public static Set<String> decisionAcceptingStatuses() {
        String raw = String.isBlank(settings().Decision_Accepting_Statuses__c) ? 'Acknowledged,Needs More Info' : settings().Decision_Accepting_Statuses__c;
        Set<String> result = new Set<String>();
        for (String s : raw.split(',')) {
            if (String.isNotBlank(s)) {
                result.add(s.trim());
            }
        }
        return result;
    }

    /** Offer terms accepted from the partner; FundMate products run 3 to 18 months. */
    public static Integer minTermMonths() {
        return Math.max(1, intOr(settings().Min_Term_Months__c, 1));
    }

    public static Integer maxTermMonths() {
        return Math.min(120, intOr(settings().Max_Term_Months__c, 120));
    }

    public static Integer logRetentionDays() {
        return Math.max(7, intOr(settings().Log_Retention_Days__c, 90));
    }

    public static Integer maxDecisionsPerRequest() {
        return Math.max(1, intOr(settings().Max_Decisions_Per_Request__c, 500));
    }

    /** Reads the protected signing secret. Null when it has not been set. */
    public static String signingSecret() {
        Underwriting_Secret__c s = Underwriting_Secret__c.getOrgDefaults();
        return s == null ? null : s.Signing_Secret__c;
    }

    private static Integer intOr(Decimal value, Integer fallback) {
        return value == null ? fallback : value.intValue();
    }

    public class ConfigException extends Exception {
    }
}
