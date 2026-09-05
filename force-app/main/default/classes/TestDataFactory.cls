@isTest
public class TestDataFactory {

    public static QueryStation__c createQueryStationRecord(String queryKey, String queryText, Boolean doInsert) {
        QueryStation__c station = new QueryStation__c(
            Query_Key__c  = queryKey,
            Query_Text__c = queryText
        );
        if (doInsert) {
            insert station;
        }
        return station;
    }

    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(Name = 'Test Account ' + i));
        }
        if (doInsert) {
            insert accounts;
        }
        return accounts;
    }

    public static User createUser(String lastName, String profileName) {
        Profile p = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String unique = lastName.toLowerCase().replaceAll('[^a-z0-9]', '') + String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User u = new User(
            LastName          = lastName,
            FirstName         = 'Test',
            Alias             = unique.left(8),
            Email             = unique + '@querystation.test',
            Username          = unique + '@querystation.test',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey      = 'en_US',
            TimeZoneSidKey    = 'America/Los_Angeles',
            ProfileId         = p.Id
        );
        insert u;
        return u;
    }

    public static void assignPermissionSet(User u, String permSetName) {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
    }
}
