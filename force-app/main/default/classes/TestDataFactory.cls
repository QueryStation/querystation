@isTest
public class TestDataFactory {

    public static QueryStation__c createQueryStationRecord(String queryKey, String queryFor, String queryText, Boolean doInsert) {
        QueryStation__c station = new QueryStation__c(
            Query_Key__c  = queryKey,
            Query_For__c  = queryFor,
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
}
