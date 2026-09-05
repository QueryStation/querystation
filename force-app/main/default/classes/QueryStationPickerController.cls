public with sharing class QueryStationPickerController {
    @AuraEnabled(cacheable=true)
    public static List<OptionItem> getPermissionSets() {
        List<OptionItem> options = new List<OptionItem>();
        for (PermissionSet ps : [
            SELECT Name, Label
            FROM PermissionSet
            WHERE IsOwnedByProfile = false
            WITH SYSTEM_MODE
            ORDER BY Label
        ]) {
            options.add(new OptionItem(ps.Label, ps.Name));
        }
        return options;
    }

    public class OptionItem {
        @AuraEnabled public String label;
        @AuraEnabled public String value;

        public OptionItem(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }
}
