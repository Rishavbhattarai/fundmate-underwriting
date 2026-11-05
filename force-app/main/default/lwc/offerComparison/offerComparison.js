import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getOffers from '@salesforce/apex/OfferComparisonController.getOffers';

const METRICS = [
    { key: 'Funding_Amount__c', label: 'Funding amount', type: 'currency', best: 'max' },
    { key: 'Factor_Rate__c', label: 'Factor rate', type: 'number', best: 'min' },
    { key: 'Term_Months__c', label: 'Term (months)', type: 'number' },
    { key: 'Payment_Frequency__c', label: 'Payment frequency', type: 'text' },
    { key: 'Number_of_Payments__c', label: 'Number of payments', type: 'number' },
    { key: 'Payment_Amount__c', label: 'Payment amount', type: 'currency', best: 'min' },
    { key: 'Total_Payback__c', label: 'Total payback', type: 'currency', best: 'min' },
    { key: 'Cost_of_Financing__c', label: 'Cost of financing', type: 'currency', best: 'min' },
    { key: 'Estimated_APR__c', label: 'Estimated APR', type: 'percent', best: 'min' }
];

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

export default class OfferComparison extends LightningElement {
    @api recordId;
    showSuperseded = false;
    offers = [];
    error;
    wiredResult;

    @wire(getOffers, { applicationId: '$recordId' })
    wiredOffers(result) {
        this.wiredResult = result;
        if (result.data) {
            this.offers = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error?.body?.message || 'Offers could not be loaded.';
            this.offers = [];
        }
    }

    get visibleOffers() {
        return this.offers.filter((o) => this.showSuperseded || !o.Superseded__c);
    }

    get hasOffers() {
        return this.visibleOffers.length > 0;
    }

    get supersededCount() {
        return this.offers.filter((o) => o.Superseded__c).length;
    }

    get hasSuperseded() {
        return this.supersededCount > 0;
    }

    get toggleLabel() {
        return this.showSuperseded ? 'Hide superseded' : `Show superseded (${this.supersededCount})`;
    }

    get columns() {
        return this.visibleOffers.map((o) => ({
            id: o.Id,
            title: o.Offer_Id__c || o.Name,
            subtitle: o.Superseded__c ? 'Superseded' : o.Underwriting_Decision__r?.Decision_Id__c || '',
            headerClass: o.Superseded__c ? 'slds-text-color_weak' : ''
        }));
    }

    /** One row per metric; the best active value in each row is marked. */
    get rows() {
        const offers = this.visibleOffers;
        return METRICS.map((m) => {
            const active = offers.filter((o) => !o.Superseded__c && o[m.key] != null);
            let bestValue;
            if (m.best && active.length > 1) {
                const values = active.map((o) => o[m.key]);
                bestValue = m.best === 'min' ? Math.min(...values) : Math.max(...values);
            }
            return {
                key: m.key,
                label: m.label,
                cells: offers.map((o) => {
                    const isBest = bestValue !== undefined && !o.Superseded__c && o[m.key] === bestValue;
                    return {
                        id: `${o.Id}-${m.key}`,
                        text: this.format(o[m.key], m.type),
                        isBest,
                        cellClass: isBest ? 'best slds-text-align_right' : 'slds-text-align_right'
                    };
                })
            };
        });
    }

    format(value, type) {
        if (value === null || value === undefined) {
            return '—';
        }
        switch (type) {
            case 'currency':
                return currency.format(value);
            case 'percent':
                return `${Number(value).toFixed(2)}%`;
            case 'number':
                return String(value);
            default:
                return value;
        }
    }

    toggleSuperseded() {
        this.showSuperseded = !this.showSuperseded;
    }

    refresh() {
        return refreshApex(this.wiredResult);
    }
}
