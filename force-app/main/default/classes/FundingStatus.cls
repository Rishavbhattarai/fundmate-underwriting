/**
 * Funding_Application__c.Status__c values, in one place so no class repeats the strings.
 */
public inherited sharing class FundingStatus {
    public static final String DRAFT = 'Draft';
    public static final String VALIDATION_FAILED = 'Validation Failed';
    public static final String READY = 'Ready';
    public static final String QUEUED = 'Queued';
    public static final String ACKNOWLEDGED = 'Acknowledged';
    public static final String REJECTED = 'Rejected';
    public static final String SEND_FAILED = 'Send Failed';
    public static final String APPROVED = 'Approved';
    public static final String DECLINED = 'Declined';
    public static final String NEEDS_MORE_INFO = 'Needs More Info';

    /** Statuses a user can send (or resend) from. */
    public static final Set<String> SENDABLE = new Set<String>{ DRAFT, VALIDATION_FAILED, SEND_FAILED };
}
