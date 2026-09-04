import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPermissionSets from '@salesforce/apex/QueryStationPickerController.getPermissionSets';
import getCustomPermissions from '@salesforce/apex/QueryStationPickerController.getCustomPermissions';

const FIELDS = [
    'QueryStation__c.Allowed_Permission_Sets__c',
    'QueryStation__c.Required_Custom_Permission__c'
];

export default class QueryStationPermissionPicker extends LightningElement {
    @api recordId;

    @track permissionSetOptions = [];
    @track customPermissionOptions = [];
    @track selectedPermSets = [];
    @track selectedCustomPerm = '';

    saving = false;
    error;

    // ── Wire: load org permission sets ──────────────────────────────────────

    @wire(getPermissionSets)
    wiredPermSets({ data, error }) {
        if (data) {
            this.permissionSetOptions = data;
        } else if (error) {
            this.error = error;
        }
    }

    @wire(getCustomPermissions)
    wiredCustomPerms({ data, error }) {
        if (data) {
            this.customPermissionOptions = [
                { label: '— None —', value: '' },
                ...data
            ];
        } else if (error) {
            this.error = error;
        }
    }

    // ── Wire: load current field values ─────────────────────────────────────

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ data, error }) {
        if (data) {
            const raw = data.fields.Allowed_Permission_Sets__c.value;
            this.selectedPermSets = raw
                ? raw.split(',').map(s => s.trim()).filter(s => s)
                : [];

            this.selectedCustomPerm =
                data.fields.Required_Custom_Permission__c.value ?? '';
        } else if (error) {
            this.error = error;
        }
    }

    // ── Getters for dual-listbox ─────────────────────────────────────────────

    get selectedPermSetsValue() {
        return this.selectedPermSets;
    }

    // ── Handlers ─────────────────────────────────────────────────────────────

    handlePermSetChange(event) {
        this.selectedPermSets = event.detail.value;
    }

    handleCustomPermChange(event) {
        this.selectedCustomPerm = event.detail.value;
    }

    async handleSave() {
        this.saving = true;
        try {
            await updateRecord({
                fields: {
                    Id: this.recordId,
                    Allowed_Permission_Sets__c: this.selectedPermSets.join(', '),
                    Required_Custom_Permission__c: this.selectedCustomPerm || null
                }
            });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Saved',
                    message: 'Permission settings updated.',
                    variant: 'success'
                })
            );
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Save failed',
                    message: e.body?.message ?? 'Unknown error',
                    variant: 'error'
                })
            );
        } finally {
            this.saving = false;
        }
    }
}
