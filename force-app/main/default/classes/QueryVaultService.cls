/**
 * Retrieves and executes externalized SOQL queries stored as QueryVault__c records.
 * Looks up a query by its Query_For__c label and runs it via Database.queryWithBinds(),
 * returning the results as a generic SObject list for the caller to cast.
 */
public with sharing class QueryVaultService {

    private static final String ERROR_BLANK_QUERY_NAME  = 'queryName cannot be blank.';
    private static final String ERROR_QUERY_NOT_FOUND   = 'No QueryVault__c record found for Query_For__c = ';
    private static final String ERROR_QUERY_TEXT_BLANK  = 'Query_Text__c is blank on QueryVault__c record: ';

    // Transaction-scoped cache to avoid repeated lookups within the same execution
    private static final Map<String, QueryVault__c> QUERY_CACHE = new Map<String, QueryVault__c>();

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Fetches the QueryVault__c record identified by queryName (Query_For__c),
     * executes its Query_Text__c via Database.queryWithBinds(), and returns the SObject list.
     * Pass bind variables as a Map so the stored query can reference named placeholders
     * (e.g. :accountId) without exposing them to SOQL injection.
     *
     * @param queryName  The exact value stored in Query_For__c on the QueryVault__c record
     * @param binds      Map of bind variable names to values (use empty map when none needed)
     * @return           List of SObjects returned by the stored query
     * @throws QueryVaultException  if the record is not found, the query text is blank,
     *                              or the dynamic SOQL fails
     * @example
     * List<SObject> results = QueryVaultService.execute(
     *     'Get Accounts By Industry',
     *     new Map<String, Object>{ 'industry' => 'Technology' }
     * );
     * List<Account> accounts = (List<Account>) results;
     */
    public static List<SObject> execute(String queryName, Map<String, Object> binds) {
        if (String.isBlank(queryName)) {
            throw new QueryVaultException(ERROR_BLANK_QUERY_NAME);
        }

        QueryVault__c vault = getRecord(queryName);

        if (String.isBlank(vault.Query_Text__c)) {
            throw new QueryVaultException(ERROR_QUERY_TEXT_BLANK + queryName);
        }

        Map<String, Object> safeBinds = binds != null ? binds : new Map<String, Object>();

        try {
            return Database.queryWithBinds(vault.Query_Text__c, safeBinds, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            throw new QueryVaultException(
                'Dynamic SOQL failed for query "' + queryName + '": ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Convenience overload for queries that require no bind variables.
     *
     * @param queryName  The exact value stored in Query_For__c on the QueryVault__c record
     * @return           List of SObjects returned by the stored query
     * @example
     * List<SObject> results = QueryVaultService.execute('Get All Accounts');
     */
    public static List<SObject> execute(String queryName) {
        return execute(queryName, new Map<String, Object>());
    }

    /**
     * Returns the QueryVault__c record for the given queryName without executing the query.
     * Useful for inspecting or modifying the query text before execution.
     *
     * @param queryName  The exact value stored in Query_For__c
     * @return           The matching QueryVault__c record
     * @throws QueryVaultException  if the record is not found
     */
    public static QueryVault__c getRecord(String queryName) {
        if (String.isBlank(queryName)) {
            throw new QueryVaultException(ERROR_BLANK_QUERY_NAME);
        }

        if (QUERY_CACHE.containsKey(queryName)) {
            return QUERY_CACHE.get(queryName);
        }

        List<QueryVault__c> records = [
            SELECT Id, Name, Query_For__c, Query_Text__c
            FROM QueryVault__c
            WHERE Query_For__c = :queryName
            WITH USER_MODE
            LIMIT 1
        ];

        if (records.isEmpty()) {
            throw new QueryVaultException(ERROR_QUERY_NOT_FOUND + queryName);
        }

        QUERY_CACHE.put(queryName, records[0]);
        return records[0];
    }

    // ─── Exception ───────────────────────────────────────────────────────────

    /**
     * Custom exception for QueryVaultService errors.
     */
    public class QueryVaultException extends Exception {}
}
