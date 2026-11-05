/**
 * Cost figures for a Funding Offer. State commercial financing disclosure laws
 * (NY, CA, FL, TX and others) ask for total cost and an estimated APR, so the
 * offer stores them for specialists. These are estimates for comparison, not
 * a legal disclosure.
 */
public inherited sharing class OfferMath {
    public static final Integer BUSINESS_DAYS_PER_MONTH = 21;

    /** Payments in the term, matching the Number_of_Payments__c formula. */
    public static Integer paymentCount(String frequency, Decimal termMonths) {
        if (termMonths == null || termMonths <= 0) {
            return null;
        }
        switch on frequency {
            when 'Daily' {
                return (termMonths * BUSINESS_DAYS_PER_MONTH).round(System.RoundingMode.HALF_UP).intValue();
            }
            when 'Weekly' {
                return (termMonths * 52 / 12).round(System.RoundingMode.HALF_UP).intValue();
            }
            when 'Monthly' {
                return termMonths.intValue();
            }
        }
        return null;
    }

    public static Integer periodsPerYear(String frequency) {
        switch on frequency {
            when 'Daily' {
                return BUSINESS_DAYS_PER_MONTH * 12;
            }
            when 'Weekly' {
                return 52;
            }
            when 'Monthly' {
                return 12;
            }
        }
        return null;
    }

    /**
     * Annual rate (as a percentage) that makes equal payments repay the amount.
     * Solved by bisection on the periodic rate; returns null when inputs are incomplete.
     */
    public static Decimal estimateApr(Decimal amount, Decimal factorRate, Decimal termMonths, String frequency) {
        Integer n = paymentCount(frequency, termMonths);
        Integer perYear = periodsPerYear(frequency);
        if (amount == null || amount <= 0 || factorRate == null || n == null || n <= 0 || perYear == null) {
            return null;
        }
        Double principal = amount.doubleValue();
        Double payment = (amount * factorRate).doubleValue() / n;
        if (payment * n <= principal) {
            return 0;
        }
        Double low = 0;
        Double high = 1;
        for (Integer i = 0; i < 100; i++) {
            Double mid = (low + high) / 2;
            Double pv = payment * (1 - Math.pow(1 + mid, -n)) / mid;
            if (pv > principal) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return Decimal.valueOf((low + high) / 2 * perYear * 100).setScale(2);
    }
}
