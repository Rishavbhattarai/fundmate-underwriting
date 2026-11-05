import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/**
 * Shows and edits the FundMate fields on a record (for example EIN on Account, SSN on Contact)
 * without changing the org's existing page layouts. lightning-record-form handles editing,
 * field-level security, encrypted-field masking and validation-rule errors.
 */
export default class FundmateFields extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api cardTitle = 'FundMate details';
    @api fieldNames = '';

    get fieldList() {
        return (this.fieldNames || '')
            .split(',')
            .map((f) => f.trim())
            .filter(Boolean);
    }

    get hasFields() {
        return this.fieldList.length > 0;
    }

    handleSuccess() {
        this.dispatchEvent(new ShowToastEvent({ title: 'Saved', message: 'FundMate details updated.', variant: 'success' }));
    }
}
