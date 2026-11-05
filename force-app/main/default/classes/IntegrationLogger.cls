/**
 * Buffers log entries and publishes them as Integration_Log_Event__e.
 * The event is set to Publish Immediately, so a log is delivered even when the
 * transaction that raised it rolls back. IntegrationLogEventHandler stores it.
 *
 * Messages pass through redact() so SSNs, EINs, dates of birth, bank figures and keys never
 * reach the log.
 */
public without sharing class IntegrationLogger {
    public enum Level {
        INFO,
        WARN,
        ERROR
    }

    private static final Integer MESSAGE_MAX = 32000;
    private static final Integer DETAILS_MAX = 131000;
    private static List<Integration_Log_Event__e> buffer = new List<Integration_Log_Event__e>();

    @TestVisible
    private static Integer publishedCount = 0;

    public static void info(String source, String message) {
        add(Level.INFO, source, message, null, null, null, null);
    }

    public static void warn(String source, String message, Id recordId) {
        add(Level.WARN, source, message, recordId, null, null, null);
    }

    public static void error(String source, String message, Id recordId) {
        add(Level.ERROR, source, message, recordId, null, null, null);
    }

    public static void error(String source, Exception ex, Id recordId) {
        add(
            Level.ERROR,
            source,
            ex.getTypeName() + ': ' + ex.getMessage(),
            recordId,
            null,
            null,
            ex.getStackTraceString()
        );
    }

    /** Full form, used by the callout and endpoint code. */
    public static void add(
        Level level,
        String source,
        String message,
        Id recordId,
        String batchKey,
        Integer httpStatus,
        String details
    ) {
        buffer.add(
            new Integration_Log_Event__e(
                Level__c = level.name(),
                Source__c = truncate(source, 120),
                Message__c = truncate(redact(message), MESSAGE_MAX),
                Details__c = truncate(redact(details), DETAILS_MAX),
                Record_Id__c = recordId,
                Batch_Key__c = batchKey,
                Http_Status__c = httpStatus,
                Limits_Snapshot__c = limitsSnapshot()
            )
        );
        if (level == IntegrationLogger.Level.ERROR) {
            // Errors are published right away, before any rollback can happen.
            flush();
        }
    }

    /** Records governor-limit usage so a run can prove it stayed within limits. */
    public static void limits(String source, String message, String batchKey) {
        add(Level.INFO, source, message, null, batchKey, null, null);
    }

    public static void flush() {
        if (buffer.isEmpty()) {
            return;
        }
        List<Integration_Log_Event__e> toPublish = buffer;
        buffer = new List<Integration_Log_Event__e>();
        List<Database.SaveResult> results = EventBus.publish(toPublish);
        for (Database.SaveResult r : results) {
            if (r.isSuccess()) {
                publishedCount++;
            } else {
                // Nowhere safer to write; the debug log is the last resort.
                System.debug(LoggingLevel.ERROR, 'Integration log publish failed: ' + r.getErrors());
            }
        }
    }

    public static String limitsSnapshot() {
        return String.join(
            new List<String>{
                'SOQL ' + Limits.getQueries() + '/' + Limits.getLimitQueries(),
                'Rows ' + Limits.getQueryRows() + '/' + Limits.getLimitQueryRows(),
                'DML ' + Limits.getDmlStatements() + '/' + Limits.getLimitDmlStatements(),
                'DML rows ' + Limits.getDmlRows() + '/' + Limits.getLimitDmlRows(),
                'CPU ' + Limits.getCpuTime() + '/' + Limits.getLimitCpuTime() + 'ms',
                'Heap ' + Limits.getHeapSize() + '/' + Limits.getLimitHeapSize(),
                'Callouts ' + Limits.getCallouts() + '/' + Limits.getLimitCallouts()
            },
            ' | '
        );
    }

    /** Masks SSNs, EINs and long secrets wherever they appear in free text. */
    public static String redact(String value) {
        if (String.isBlank(value)) {
            return value;
        }
        String out = value;
        out = out.replaceAll('\\b\\d{3}-?\\d{2}-?(\\d{4})\\b', '***-**-$1');
        out = out.replaceAll('\\b\\d{2}-(\\d{7})\\b', '**-*******');
        // Key-based: anything labelled as an identifier, a secret, a date of birth or bank data.
        out = out.replaceAll(
            '(?i)("?(ssn|ein|x-api-key|apikey|secret|signature|dateofbirth|date_of_birth__c|dob|birthdate|averagemonthlydeposits|totaldeposits|total_deposits__c|nsfcount|totalnsfcount)"?\\s*[:=]\\s*"?)[^",\\s}]+',
            '$1[REDACTED]'
        );
        return out;
    }

    private static String truncate(String value, Integer max) {
        if (value == null || value.length() <= max) {
            return value;
        }
        return value.left(max);
    }
}
