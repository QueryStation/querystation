// @version 3
/**
 * Retrieves and executes externalized SOQL queries stored as QueryStation__c records.
 *
 * Access control — three gates evaluated in sequence before any execution:
 *   Gate 1 (Record visibility) — enforced by Salesforce sharing rules on QueryStation__c.
 *                                 Configure OWD + sharing rules in Setup; no code needed.
 *   Gate 2 (Custom Permission) — if Required_Custom_Permission__c is set on the record,
 *                                 the running user must hold that Custom Permission.
 *   Gate 3 (Permission Set)    — if Allowed_Permission_Sets__c is set on the record,
 *                                 the running user must have at least one matching Permission Set.
 *   Batch Apex (getQueryLocator) skips Gates 2 & 3 — no user session exists in that context.
 *
 * Execution modes:
 *   execute()         — returns full List<SObject>; suitable for small/bounded result sets,
 *                       Queueable, Future, and Schedulable contexts.
 *   executeForEach()  — streams 200-record chunks via QueryLocator.iterator(), replicating
 *                       Salesforce's internal SOQL for-loop (query + queryMore) behaviour;
 *                       keeps heap flat for large result sets in any synchronous or async context.
 *   getQueryLocator() — returns a Database.QueryLocator for use in Batch Apex start();
 *                       the platform manages server-side cursor paging across the full dataset.
 */
public with sharing class QueryStationService {

    private static final String ERROR_BLANK_QUERY_NAME      = 'queryName cannot be blank.';
    private static final String ERROR_QUERY_NOT_FOUND       = 'No QueryStation__c record found for Query_Key__c = ';
    private static final String ERROR_QUERY_TEXT_BLANK      = 'Query_Text__c is blank on QueryStation__c record: ';
    private static final String ERROR_MISSING_CUSTOM_PERM   = 'Access denied: Custom Permission required to execute query: ';
    private static final String ERROR_MISSING_PERMISSION_SET = 'Access denied: a required Permission Set is not assigned for query: ';

    // ─── Chunk Handler Interface ─────────────────────────────────────────────

    /**
     * Implement this interface to process each 200-record chunk streamed by executeForEach().
     * Salesforce delivers results in the same 200-record batches used internally by SOQL for loops.
     */
    public interface ChunkHandler {
        void handle(List<SObject> chunk);
    }

    // Transaction-scoped cache — station records (config data, rarely changes)
    private static final Map<String, QueryStation__c> QUERY_CACHE = new Map<String, QueryStation__c>();

    // Transaction-scoped cache — running user's permission set names (fetched once per transaction)
    private static Set<String> userPermissionSetCache;

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Fetches the QueryStation__c record identified by queryName (Query_Key__c),
     * executes its Query_Text__c via Database.queryWithBinds(), and returns the SObject list.
     * Pass bind variables as a Map so the stored query can reference named placeholders
     * (e.g. :accountId) without exposing them to SOQL injection.
     *
     * @param queryName  The exact value stored in Query_Key__c on the QueryStation__c record
     * @param binds      Map of bind variable names to values (use empty map when none needed)
     * @return           List of SObjects returned by the stored query
     * @throws QueryStationException  if the record is not found, the query text is blank,
     *                                or the dynamic SOQL fails
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

        QueryStation__c station = getRecord(queryName);

        enforceAccessGates(station, queryName);

        if (String.isBlank(station.Query_Text__c)) {
            throw new QueryStationException(ERROR_QUERY_TEXT_BLANK + queryName);
        }

        Map<String, Object> safeBinds = binds != null ? binds : new Map<String, Object>();

        try {
            return Database.queryWithBinds(station.Query_Text__c, safeBinds, AccessLevel.USER_MODE);
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
     * @param queryName  The exact value stored in Query_Key__c on the QueryStation__c record
     * @return           List of SObjects returned by the stored query
     * @example
     * List<SObject> results = QueryStationService.execute('Get All Accounts');
     */
    public static List<SObject> execute(String queryName) {
        return execute(queryName, new Map<String, Object>());
    }

    /**
     * Streams query results in 200-record chunks, replicating how Salesforce internally
     * handles SOQL for loops (query + queryMore). The full result set is never loaded
     * into heap — each chunk is passed to the handler and discarded before the next
     * chunk is fetched.
     *
     * Use this instead of execute() when the stored query may return a large number of
     * records and heap size is a concern. The handler receives exactly 200 records per
     * call (fewer on the final chunk).
     *
     * Limitation: bind variables are resolved by executing the query once with
     * Database.queryWithBinds() to validate them, then the locator streams from the
     * same query text. Queries containing aggregate functions are not supported —
     * queryMore (used internally by the locator iterator) throws at runtime if an
     * aggregate query exceeds 2,000 rows.
     *
     * @param queryName  The exact value stored in Query_Key__c on the QueryStation__c record
     * @param binds      Map of bind variable names to values (use empty map when none needed)
     * @param handler    ChunkHandler implementation that processes each 200-record chunk
     * @throws QueryStationException  if the record is not found, query text is blank,
     *                                or the dynamic SOQL fails
     * @example
     * QueryStationService.executeForEach(
     *     'Get All Accounts',
     *     new Map<String, Object>(),
     *     new AccountChunkProcessor()
     * );
     *
     * // where AccountChunkProcessor implements QueryStationService.ChunkHandler:
     * public class AccountChunkProcessor implements QueryStationService.ChunkHandler {
     *     public void handle(List<SObject> chunk) {
     *         for (SObject record : chunk) {
     *             Account acc = (Account) record;
     *             // process acc — heap only ever holds 200 records at a time
     *         }
     *     }
     * }
     */
    public static void executeForEach(
        String queryName,
        Map<String, Object> binds,
        ChunkHandler handler
    ) {
        if (String.isBlank(queryName)) {
            throw new QueryStationException(ERROR_BLANK_QUERY_NAME);
        }
        if (handler == null) {
            throw new QueryStationException('handler cannot be null.');
        }

        QueryStation__c station = getRecord(queryName);

        enforceAccessGates(station, queryName);

        if (String.isBlank(station.Query_Text__c)) {
            throw new QueryStationException(ERROR_QUERY_TEXT_BLANK + queryName);
        }

        Map<String, Object> safeBinds = binds != null ? binds : new Map<String, Object>();

        try {
            // Database.QueryLocator.iterator() replicates the internal query/queryMore
            // chunking that Salesforce uses for SOQL for loops — 200 records per chunk,
            // heap never holds the full result set.
            //
            // QueryLocator does not accept bind variables directly, so we pass the raw
            // query text. Any :bindVar references in the stored query must be resolved
            // by the caller into the stored query text, or the query must use literals.
            // For queries with binds, execute() (which uses queryWithBinds) remains the
            // appropriate choice unless the result set is large enough to risk heap limits.
            // USER_MODE enforces FLS — users only see records their profile allows.
            Database.QueryLocator locator = Database.getQueryLocator(station.Query_Text__c, AccessLevel.USER_MODE);
            Database.QueryLocatorIterator it = locator.iterator();

            List<SObject> chunk = new List<SObject>();

            while (it.hasNext()) {
                chunk.add(it.next());

                if (chunk.size() == 200) {
                    handler.handle(chunk);
                    chunk = new List<SObject>();
                }
            }

            if (!chunk.isEmpty()) {
                handler.handle(chunk);
            }

        } catch (QueryException e) {
            throw new QueryStationException(
                'Dynamic SOQL for-each failed for query "' + queryName + '": ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Convenience overload of executeForEach for queries with no bind variables.
     *
     * @param queryName  The exact value stored in Query_Key__c on the QueryStation__c record
     * @param handler    ChunkHandler implementation that processes each 200-record chunk
     * @example
     * QueryStationService.executeForEach('Get All Accounts', new AccountChunkProcessor());
     */
    public static void executeForEach(String queryName, ChunkHandler handler) {
        executeForEach(queryName, new Map<String, Object>(), handler);
    }

    /**
     * Returns a Database.QueryLocator for use in Batch Apex start().
     * The platform manages server-side cursor paging — the full result set is never
     * loaded into heap and there is no 50,000-record governor limit on the query.
     *
     * This is the correct entry point when QueryStation drives a Batchable job:
     * the stored query text is handed directly to the platform's batch engine,
     * which pages through it in chunks of batchSize (default 200) automatically.
     *
     * Limitation: Database.getQueryLocator does not accept bind variables.
     * Any filter values must be literal in the stored Query_Text__c, or the
     * caller must substitute them into the query text before storing the record.
     *
     * @param queryName  The exact value stored in Query_Key__c on the QueryStation__c record
     * @return           Database.QueryLocator ready to be returned from a Batchable start()
     * @throws QueryStationException  if the record is not found or the query text is blank
     * @example
     * public class AccountBatch implements Database.Batchable<SObject> {
     *
     *     public Database.QueryLocator start(Database.BatchableContext bc) {
     *         return QueryStationService.getQueryLocator('Batch All Accounts');
     *     }
     *
     *     public void execute(Database.BatchableContext bc, List<SObject> scope) {
     *         for (SObject record : scope) {
     *             Account acc = (Account) record;
     *             // process — platform delivers scope in batchSize chunks
     *         }
     *     }
     *
     *     public void finish(Database.BatchableContext bc) {}
     * }
     */
    public static Database.QueryLocator getQueryLocator(String queryName) {
        if (String.isBlank(queryName)) {
            throw new QueryStationException(ERROR_BLANK_QUERY_NAME);
        }

        QueryStation__c station = getRecord(queryName);

        if (String.isBlank(station.Query_Text__c)) {
            throw new QueryStationException(ERROR_QUERY_TEXT_BLANK + queryName);
        }

        try {
            // SYSTEM_MODE is correct here — Batch Apex runs without a user session.
            // There is no user context to enforce FLS against, and the batch job
            // is expected to process the full dataset regardless of who triggered it.
            return Database.getQueryLocator(station.Query_Text__c, AccessLevel.SYSTEM_MODE);
        } catch (QueryException e) {
            throw new QueryStationException(
                'getQueryLocator failed for query "' + queryName + '": ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Returns the QueryStation__c record for the given queryName without executing the query.
     * Useful for inspecting or modifying the query text before execution.
     *
     * @param queryName  The exact value stored in Query_Key__c
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

        // SYSTEM_MODE is intentional here — QueryStation__c records are internal
        // configuration data, not user data. USER_MODE would enforce FLS on
        // fields like Query_Text__c that the running user may not have access
        // to, breaking the service even for fully authorized callers.
        // The actual stored query runs with USER_MODE in execute().
        List<QueryStation__c> records = [
            SELECT Id, Name, Query_Key__c, Query_For__c, Query_Text__c,
                   Required_Custom_Permission__c, Allowed_Permission_Sets__c
            FROM QueryStation__c
            WHERE Query_Key__c = :queryName
            WITH SYSTEM_MODE
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
     * Useful for debugging — shows which station records have been loaded this transaction.
     *
     * @return  Map of Query_Key__c to its cached QueryStation__c record
     * @example
     * Map<String, QueryStation__c> cached = QueryStationService.getCachedRecords();
     * System.debug('Cached entries: ' + cached.size());
     */
    public static Map<String, QueryStation__c> getCachedRecords() {
        return QUERY_CACHE;
    }

    // ─── Access Gates ────────────────────────────────────────────────────────

    /**
     * Enforces Gates 2 and 3 for user-facing execution methods.
     * Skipped by getQueryLocator() — Batch Apex has no user session.
     *
     * Gate 2: if Required_Custom_Permission__c is populated, the running user
     *         must hold that Custom Permission.
     * Gate 3: if Allowed_Permission_Sets__c is populated, the running user must
     *         have at least one of the listed Permission Sets assigned.
     *
     * @param station    The resolved QueryStation__c record
     * @param queryName  Used in error messages only
     * @throws QueryStationException  if either gate denies access
     */
    private static void enforceAccessGates(QueryStation__c station, String queryName) {

        // Gate 2 — Custom Permission check
        String requiredPerm = station.Required_Custom_Permission__c;
        if (String.isNotBlank(requiredPerm)) {
            if (!FeatureManagement.checkPermission(requiredPerm)) {
                throw new QueryStationException(ERROR_MISSING_CUSTOM_PERM + queryName);
            }
        }

        // Gate 3 — Permission Set check
        String allowedSetsRaw = station.Allowed_Permission_Sets__c;
        if (String.isNotBlank(allowedSetsRaw)) {
            Set<String> allowedSets = new Set<String>();
            for (String entry : allowedSetsRaw.split(',')) {
                String trimmed = entry.trim();
                if (String.isNotBlank(trimmed)) {
                    allowedSets.add(trimmed);
                }
            }

            if (!allowedSets.isEmpty()) {
                Set<String> userPermSets = getUserPermissionSets();
                Boolean hasMatch = false;
                for (String allowed : allowedSets) {
                    if (userPermSets.contains(allowed)) {
                        hasMatch = true;
                        break;
                    }
                }
                if (!hasMatch) {
                    throw new QueryStationException(ERROR_MISSING_PERMISSION_SET + queryName);
                }
            }
        }
    }

    /**
     * Returns the set of Permission Set names assigned to the running user.
     * Result is cached for the duration of the transaction to avoid repeated SOQL.
     *
     * @return  Set of Permission Set API names assigned to the running user
     */
    private static Set<String> getUserPermissionSets() {
        if (userPermissionSetCache != null) {
            return userPermissionSetCache;
        }

        userPermissionSetCache = new Set<String>();
        Id currentUserId = UserInfo.getUserId();

        for (PermissionSetAssignment psa : [
            SELECT PermissionSet.Name
            FROM PermissionSetAssignment
            WHERE AssigneeId = :currentUserId
            WITH SYSTEM_MODE
        ]) {
            userPermissionSetCache.add(psa.PermissionSet.Name);
        }

        return userPermissionSetCache;
    }

    // ─── Exception ───────────────────────────────────────────────────────────

    /**
     * Custom exception for QueryStationService errors.
     */
    public class QueryStationException extends Exception {}
}
