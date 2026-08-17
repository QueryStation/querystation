/**
 * Retrieves and executes externalized SOQL queries stored as QueryStation__c records.
 * Looks up a query by its Query_For__c label and runs it via Database.queryWithBinds(),
 * returning the results as a generic SObject list for the caller to cast.
 */
public with sharing class QueryStationService {

    private static final String ERROR_BLANK_QUERY_NAME  = 'queryName cannot be blank.';
    private static final String ERROR_QUERY_NOT_FOUND   = 'No QueryStation__c record found for Query_For__c = ';
    private static final String ERROR_QUERY_TEXT_BLANK  = 'Query_Text__c is blank on QueryStation__c record: ';

    // Transaction-scoped cache to avoid repeated lookups within the same execution
    private static final Map<String, QueryStation__c> QUERY_CACHE = new Map<String, QueryStation__c>();

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Fetches the QueryStation__c record identified by queryName (Query_For__c),
     * executes its Query_Text__c via Database.queryWithBinds(), and returns the SObject list.
     * Pass bind variables as a Map so the stored query can reference named placeholders
     * (e.g. :accountId) without exposing them to SOQL injection.
     *
     * @param queryName  The exact value stored in Query_For__c on the QueryStation__c record
     * @param binds      Map of bind variable names to values (use empty map when none needed)
     * @return           List of SObjects returned by the stored query
     * @throws QueryStationException  if the record is not found, the query text is blank,
     *                              or the dynamic SOQL fails
     * @example
     * List<SObject> results = QueryStationService.execute(
     *     'Get Accounts By Industry',
     *     new Map<String, Object>{ 'industry' => 'Technology' }
     * );
     * List<Account> accounts = (List<Account>) results;
     */
    public static List<SObject> execute(String queryName, Map<String, Object> binds) {
        if (String.isBlank(queryName)) {
            throw new QueryStationException(ERROR_BLANK_QUERY_NAME);
        }

        QueryStation__c vault = getRecord(queryName);

        if (String.isBlank(vault.Query_Text__c)) {
            throw new QueryStationException(ERROR_QUERY_TEXT_BLANK + queryName);
        }

        Map<String, Object> safeBinds = binds != null ? binds : new Map<String, Object>();

        try {
            return Database.queryWithBinds(vault.Query_Text__c, safeBinds, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            throw new QueryStationException(
                'Dynamic SOQL failed for query "' + queryName + '": ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Convenience overload for queries that require no bind variables.
     *
     * @param queryName  The exact value stored in Query_For__c on the QueryStation__c record
     * @return           List of SObjects returned by the stored query
     * @example
     * List<SObject> results = QueryStationService.execute('Get All Accounts');
     */
    public static List<SObject> execute(String queryName) {
        return execute(queryName, new Map<String, Object>());
    }

    /**
     * Returns the QueryStation__c record for the given queryName without executing the query.
     * Useful for inspecting or modifying the query text before execution.
     *
     * @param queryName  The exact value stored in Query_For__c
     * @return           The matching QueryStation__c record
     * @throws QueryStationException  if the record is not found
     */
    public static QueryStation__c getRecord(String queryName) {
        if (String.isBlank(queryName)) {
            throw new QueryStationException(ERROR_BLANK_QUERY_NAME);
        }

        if (QUERY_CACHE.containsKey(queryName)) {
            return QUERY_CACHE.get(queryName);
        }

        List<QueryStation__c> records = [
            SELECT Id, Name, Query_For__c, Query_Text__c
            FROM QueryStation__c
            WHERE Query_For__c = :queryName
            WITH USER_MODE
            LIMIT 1
        ];

        if (records.isEmpty()) {
            throw new QueryStationException(ERROR_QUERY_NOT_FOUND + queryName);
        }

        QUERY_CACHE.put(queryName, records[0]);
        return records[0];
    }

    /**
     * Returns the current state of the transaction-scoped cache.
     * Useful for debugging — shows which vault records have been loaded this transaction.
     *
     * @return  Map of Query_For__c label to its cached QueryStation__c record
     * @example
     * Map<String, QueryStation__c> cached = QueryStationService.getCachedRecords();
     * System.debug('Cached entries: ' + cached.size());
     */
    public static Map<String, QueryStation__c> getCachedRecords() {
        return QUERY_CACHE;
    }

    // ─── Exception ───────────────────────────────────────────────────────────

    /**
     * Custom exception for QueryStationService errors.
     */
    public class QueryStationException extends Exception {}
}
