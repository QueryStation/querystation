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

    @AuraEnabled(cacheable=true)
    public static List<OptionItem> getCustomPermissions() {
        List<OptionItem> options = new List<OptionItem>();
        for (CustomPermission cp : [
            SELECT DeveloperName, MasterLabel
            FROM CustomPermission
            WITH SYSTEM_MODE
            ORDER BY MasterLabel
        ]) {
            options.add(new OptionItem(cp.MasterLabel, cp.DeveloperName));
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
