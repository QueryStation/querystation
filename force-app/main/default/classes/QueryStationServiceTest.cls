/**
 * Test class for QueryStationService.
 *
 * Covers:
 *   execute()         — positive, bind variables, blank queryName, record not found, blank query text
 *   executeForEach()  — chunk boundary (exactly 200), remainder chunk (<200), null handler
 *   getQueryLocator() — positive, blank queryName, record not found
 *   getRecord()       — cache hit (no second SOQL), record not found
 *
 * Bulk note: Apex tests cannot insert 50M records (DML cap = 10,000 per transaction).
 * The chunk boundary tests insert 250 records to cross the 200-record boundary, proving
 * the chunking logic fires correctly at exactly the same boundaries it would at 50M records —
 * because the logic is positional, not data-volume-dependent.
 */
@isTest
private class QueryStationServiceTest {

    // Query_Key__c is the unique required lookup key — this is what QueryStationService queries by
    private static final String KEY_ALL_ACCOUNTS   = 'get-all-accounts';
    private static final String KEY_BULK_ACCOUNTS  = 'get-bulk-accounts';
    private static final String KEY_WITH_BIND      = 'get-accounts-by-name';
    private static final String KEY_EMPTY_QUERY    = 'empty-query';

    private static final String QUERY_TEXT_ALL_ACCOUNTS  = 'SELECT Id, Name FROM Account ORDER BY Name';
    private static final String QUERY_TEXT_BULK_ACCOUNTS = 'SELECT Id, Name FROM Account ORDER BY Name';
    private static final String QUERY_TEXT_WITH_BIND     = 'SELECT Id, Name FROM Account WHERE Name = :accountName';

    // ─── Chunk counter — counts handler invocations in executeForEach tests ──

    private class ChunkCounter implements QueryStationService.ChunkHandler {
        public Integer callCount    = 0;
        public Integer totalRecords = 0;
        public List<Integer> chunkSizes = new List<Integer>();

        public void handle(List<SObject> chunk) {
            callCount++;
            totalRecords += chunk.size();
            chunkSizes.add(chunk.size());
        }
    }

    // ─── execute() — positive ────────────────────────────────────────────────

    @isTest
    static void shouldReturnRecords_WhenQueryExecutes() {
        // Given
        TestDataFactory.createAccounts(5, true);
        TestDataFactory.createQueryStationRecord(KEY_ALL_ACCOUNTS, 'Get All Accounts', QUERY_TEXT_ALL_ACCOUNTS, true);

        // When
        Test.startTest();
        List<SObject> results = QueryStationService.execute(KEY_ALL_ACCOUNTS);
        Test.stopTest();

        // Then
        Assert.areEqual(5, results.size(), 'execute() should return all 5 accounts');
    }

    // ─── execute() — with bind variables ─────────────────────────────────────

    @isTest
    static void shouldReturnFilteredRecords_WhenBindVariableProvided() {
        // Given
        TestDataFactory.createAccounts(5, true);
        insert new Account(Name = 'Target Account');
        TestDataFactory.createQueryStationRecord(KEY_WITH_BIND, 'Get Accounts By Name', QUERY_TEXT_WITH_BIND, true);

        // When
        Test.startTest();
        List<SObject> results = QueryStationService.execute(
            KEY_WITH_BIND,
            new Map<String, Object>{ 'accountName' => 'Target Account' }
        );
        Test.stopTest();

        // Then
        Assert.areEqual(1, results.size(), 'execute() should return only the matching account');
        Assert.areEqual('Target Account', (String) results[0].get('Name'),
            'Returned record name should match the bind value');
    }

    // ─── execute() — blank queryName ─────────────────────────────────────────

    @isTest
    static void shouldThrowException_WhenQueryNameIsBlank() {
        // When / Then
        Test.startTest();
        try {
            QueryStationService.execute('');
            Assert.fail('Expected QueryStationException for blank queryName');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('queryName cannot be blank'),
                'Exception should state queryName cannot be blank');
        }
        Test.stopTest();
    }

    // ─── execute() — record not found ────────────────────────────────────────

    @isTest
    static void shouldThrowException_WhenQueryStationRecordNotFound() {
        // When / Then
        Test.startTest();
        try {
            QueryStationService.execute('Nonexistent Query');
            Assert.fail('Expected QueryStationException for missing station record');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('No QueryStation__c record found'),
                'Exception should state record not found');
        }
        Test.stopTest();
    }

    // ─── execute() — blank query text on station record ──────────────────────

    @isTest
    static void shouldThrowException_WhenQueryTextIsBlank() {
        // Given — station record exists but Query_Text__c is empty
        TestDataFactory.createQueryStationRecord(KEY_EMPTY_QUERY, 'Empty Query', '', true);

        // When / Then
        Test.startTest();
        try {
            QueryStationService.execute(KEY_EMPTY_QUERY);
            Assert.fail('Expected QueryStationException for blank query text');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('Query_Text__c is blank'),
                'Exception should state query text is blank');
        }
        Test.stopTest();
    }

    // ─── executeForEach() — exactly 200 records (single full chunk) ──────────

    @isTest
    static void shouldCallHandlerOnce_WhenResultSetIsExactly200() {
        // Given
        TestDataFactory.createAccounts(200, true);
        TestDataFactory.createQueryStationRecord(KEY_BULK_ACCOUNTS, 'Get Bulk Accounts', QUERY_TEXT_BULK_ACCOUNTS, true);
        ChunkCounter counter = new ChunkCounter();

        // When
        Test.startTest();
        QueryStationService.executeForEach(KEY_BULK_ACCOUNTS, counter);
        Test.stopTest();

        // Then — 200 records fills exactly one chunk; handler called once with 200
        Assert.areEqual(1, counter.callCount,
            'Handler should be called exactly once for 200 records');
        Assert.areEqual(200, counter.chunkSizes[0],
            'The single chunk should contain exactly 200 records');
        Assert.areEqual(200, counter.totalRecords,
            'Total records processed should be 200');
    }

    // ─── executeForEach() — 250 records (full chunk + remainder) ─────────────
    //
    // This is the core bulk boundary test. At 50M records the same code path fires:
    // handler is called once per 200 records, then once for the remainder.
    // The chunking logic is positional — 250 here proves the same boundaries as 50M.

    @isTest
    static void shouldCallHandlerTwice_WhenResultSetCrossesChunkBoundary() {
        // Given — 250 records: one full chunk of 200 + remainder of 50
        TestDataFactory.createAccounts(250, true);
        TestDataFactory.createQueryStationRecord(KEY_BULK_ACCOUNTS, 'Get Bulk Accounts', QUERY_TEXT_BULK_ACCOUNTS, true);
        ChunkCounter counter = new ChunkCounter();

        // When
        Test.startTest();
        QueryStationService.executeForEach(KEY_BULK_ACCOUNTS, counter);
        Test.stopTest();

        // Then
        Assert.areEqual(2, counter.callCount,
            'Handler should be called twice: once for 200, once for the 50 remainder');
        Assert.areEqual(200, counter.chunkSizes[0],
            'First chunk should be exactly 200 records');
        Assert.areEqual(50, counter.chunkSizes[1],
            'Second (remainder) chunk should be exactly 50 records');
        Assert.areEqual(250, counter.totalRecords,
            'Total records across all chunks should be 250');
    }

    // ─── executeForEach() — fewer than 200 records (remainder-only path) ─────

    @isTest
    static void shouldCallHandlerOnce_WhenResultSetIsUnder200() {
        // Given
        TestDataFactory.createAccounts(75, true);
        TestDataFactory.createQueryStationRecord(KEY_BULK_ACCOUNTS, 'Get Bulk Accounts', QUERY_TEXT_BULK_ACCOUNTS, true);
        ChunkCounter counter = new ChunkCounter();

        // When
        Test.startTest();
        QueryStationService.executeForEach(KEY_BULK_ACCOUNTS, counter);
        Test.stopTest();

        // Then — never fills a full chunk; goes straight to the remainder flush
        Assert.areEqual(1, counter.callCount,
            'Handler should be called once for a sub-200 result set');
        Assert.areEqual(75, counter.chunkSizes[0],
            'The single chunk should contain all 75 records');
        Assert.areEqual(75, counter.totalRecords,
            'Total records should be 75');
    }

    // ─── executeForEach() — null handler ─────────────────────────────────────

    @isTest
    static void shouldThrowException_WhenHandlerIsNull() {
        // Given
        TestDataFactory.createQueryStationRecord(KEY_BULK_ACCOUNTS, 'Get Bulk Accounts', QUERY_TEXT_BULK_ACCOUNTS, true);

        // When / Then
        Test.startTest();
        try {
            QueryStationService.executeForEach(KEY_BULK_ACCOUNTS, null);
            Assert.fail('Expected QueryStationException for null handler');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('handler cannot be null'),
                'Exception should state handler cannot be null');
        }
        Test.stopTest();
    }

    // ─── getQueryLocator() — positive ────────────────────────────────────────

    @isTest
    static void shouldReturnQueryLocator_WhenValidQueryName() {
        // Given
        TestDataFactory.createAccounts(10, true);
        TestDataFactory.createQueryStationRecord(KEY_ALL_ACCOUNTS, 'Get All Accounts', QUERY_TEXT_ALL_ACCOUNTS, true);

        // When
        Test.startTest();
        Database.QueryLocator locator = QueryStationService.getQueryLocator(KEY_ALL_ACCOUNTS);
        Test.stopTest();

        // Then
        Assert.isNotNull(locator, 'getQueryLocator() should return a non-null QueryLocator');
    }

    // ─── getQueryLocator() — blank queryName ─────────────────────────────────

    @isTest
    static void shouldThrowException_WhenGetQueryLocatorReceivesBlankName() {
        // When / Then
        Test.startTest();
        try {
            QueryStationService.getQueryLocator('');
            Assert.fail('Expected QueryStationException for blank queryName');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('queryName cannot be blank'),
                'Exception should state queryName cannot be blank');
        }
        Test.stopTest();
    }

    // ─── getQueryLocator() — record not found ────────────────────────────────

    @isTest
    static void shouldThrowException_WhenGetQueryLocatorRecordNotFound() {
        // When / Then
        Test.startTest();
        try {
            QueryStationService.getQueryLocator('Nonexistent Query');
            Assert.fail('Expected QueryStationException for missing station record');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('No QueryStation__c record found'),
                'Exception should state record not found');
        }
        Test.stopTest();
    }

    // ─── getRecord() — cache hit ──────────────────────────────────────────────
    //
    // Proves the transaction-scoped cache works: two calls to getRecord() with
    // the same queryName should consume only 1 extra SOQL (the station lookup),
    // not 2. We verify the cache by checking getCachedRecords() is populated
    // after the first call and that a second call returns the same record Id.

    @isTest
    static void shouldReturnCachedRecord_WhenCalledTwiceWithSameName() {
        // Given
        TestDataFactory.createQueryStationRecord(KEY_ALL_ACCOUNTS, 'Get All Accounts', QUERY_TEXT_ALL_ACCOUNTS, true);

        // When
        Test.startTest();
        QueryStation__c first  = QueryStationService.getRecord(KEY_ALL_ACCOUNTS);
        QueryStation__c second = QueryStationService.getRecord(KEY_ALL_ACCOUNTS);
        Test.stopTest();

        // Then
        Assert.areEqual(first.Id, second.Id,
            'Both calls should return the same cached record');
        Assert.areEqual(1, QueryStationService.getCachedRecords().size(),
            'Cache should hold exactly one entry');
    }

    // ─── getRecord() — record not found ──────────────────────────────────────

    @isTest
    static void shouldThrowException_WhenGetRecordNotFound() {
        // When / Then
        Test.startTest();
        try {
            QueryStationService.getRecord('Does Not Exist');
            Assert.fail('Expected QueryStationException for missing station record');
        } catch (QueryStationService.QueryStationException e) {
            Assert.isTrue(e.getMessage().contains('No QueryStation__c record found'),
                'Exception should state record not found');
        }
        Test.stopTest();
    }
}
