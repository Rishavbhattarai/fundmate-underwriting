/**
 * Scheduled sweep. Sends Ready applications, including retries whose wait was
 * longer than the 10-minute Queueable delay.
 *
 * Schedule every 15 minutes from Anonymous Apex:
 *   UnderwritingScheduler.scheduleEvery15Minutes();
 */
public with sharing class UnderwritingScheduler implements Schedulable {
    public static final String JOB_PREFIX = 'FundMate Underwriting Send';

    public void execute(SchedulableContext context) {
        // Scheduled Apex can't make callouts directly; the dispatcher starts a batch that can.
        System.enqueueJob(new UnderwritingDispatcher());
    }

    public static List<Id> scheduleEvery15Minutes() {
        List<Id> ids = new List<Id>();
        for (Integer minute : new List<Integer>{ 0, 15, 30, 45 }) {
            String name = JOB_PREFIX + ' :' + String.valueOf(minute).leftPad(2, '0');
            ids.add(System.schedule(name, '0 ' + minute + ' * * * ?', new UnderwritingScheduler()));
        }
        return ids;
    }
}
