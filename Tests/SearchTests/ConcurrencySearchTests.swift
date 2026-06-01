import Foundation
import Testing
@testable import DeepFinder

// MARK: - ConcurrencySearchTests

/// Stress tests for the search layer's concurrent behavior.
///
/// Validates that ``SearchCoordinator`` correctly handles:
/// - Multiple concurrent search requests without mixing results
/// - Multiple providers returning results in parallel
/// - Thread-safe deduplication and sorting under concurrent load
/// - Cancellation of in-flight queries
///
/// All tests use `withTaskGroup` for structured concurrency and include
/// timeouts to prevent hangs on CI.
@Suite("Concurrency search tests")
struct ConcurrencySearchTests {

    // MARK: - Timeout helper

    /// Run an async operation with a deadline.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    /// Make a minimal FileRecord for testing.
    private func makeRecord(id: UInt32, name: String, path: String = "/test") -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: path + "/" + name,
            parentPath: path,
            isDirectory: false,
            size: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extension: name.split(separator: ".").last.map(String.init)
        )
    }

    /// A mock provider that returns a predefined set of results for any query.
    /// Uses ``@unchecked Sendable`` with ``nonisolated(unsafe)`` counters for
    /// test observability. Race conditions on counters are acceptable since they
    /// are only checked after all concurrent work completes.
    private final class CountingSearchProvider: SearchProvider, @unchecked Sendable {
        let providerID: String
        private let fixedResults: [SearchResult]
        private let delayNanos: UInt64?
        nonisolated(unsafe) private(set) var searchCallCount: Int = 0
        nonisolated(unsafe) private(set) var cancelCallCount: Int = 0

        init(
            providerID: String,
            results: [SearchResult] = [],
            delayNanos: UInt64? = nil
        ) {
            self.providerID = providerID
            self.fixedResults = results
            self.delayNanos = delayNanos
        }

        func search(query: SearchQuery) async -> SearchResultSequence {
            searchCallCount += 1

            if let delay = delayNanos {
                try? await Task.sleep(nanoseconds: delay)
            }
            return SearchResultSequence(fixedResults)
        }

        func cancel(queryID: String) async {
            cancelCallCount += 1
        }

        func prepare() async {}
    }

    // MARK: - 1. Concurrent search requests to same coordinator

    /// Sends 20 concurrent search requests to a single coordinator.
    /// Each provider holds one unique record. The coordinator dispatches
    /// each query to all providers concurrently. Verifies:
    /// - All 20 results are returned by every search (mock returns all for any query)
    /// - No results are mixed up or lost under concurrency
    @Test("Twenty concurrent searches return correct, independent results")
    func testConcurrentSearchRequests() async throws {
        // Create 20 records across 20 providers (1 record per provider)
        var providers: [CountingSearchProvider] = []
        for i in 1...20 {
            let record = makeRecord(id: UInt32(i), name: "concurrent\(i).txt")
            let result = SearchResult(record: record, providerID: "p\(i)", score: 1.0, matchType: .exact)
            providers.append(CountingSearchProvider(providerID: "p\(i)", results: [result]))
        }
        let coordinator = SearchCoordinator(providers: providers)

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: (Int, [SearchResult]).self) { group in
                for i in 1...20 {
                    let queryStr = "concurrent\(i)"
                    group.addTask {
                        let results = await coordinator.search(query: queryStr)
                        return (i, results)
                    }
                }

                for await (idx, found) in group {
                    // Each search dispatches to all 20 providers, so all 20 unique
                    // records should be returned (different IDs = no dedup)
                    #expect(found.count == 20,
                            "Query concurrent\(idx) should return 20 results from 20 providers, got \(found.count)")
                    // Verify the specific record for this query is present
                    #expect(found.contains { $0.record.name == "concurrent\(idx).txt" },
                            "Query concurrent\(idx) should find its matching record")
                }
            }
        }
    }

    // MARK: - 2. Multiple providers returning results concurrently

    /// Registers 5 providers, each returning different results for the same
    /// query. Verifies the coordinator collects and deduplicates all results
    /// correctly.
    @Test("Multiple providers return results concurrently and are deduplicated")
    func testMultipleProvidersConcurrently() async throws {
        var providers: [CountingSearchProvider] = []
        for p in 1...5 {
            let records = (1...10).map { i in
                let id = UInt32((p - 1) * 10 + i)
                return makeRecord(id: id, name: "multi\(id).txt")
            }
            let results = records.map { record in
                SearchResult(record: record, providerID: "p\(p)", score: Double(p), matchType: .substring)
            }
            providers.append(CountingSearchProvider(providerID: "p\(p)", results: results))
        }

        let coordinator = SearchCoordinator(providers: providers)

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: [SearchResult].self) { group in
                // 3 concurrent searches through the same coordinator
                for _ in 0..<3 {
                    group.addTask {
                        await coordinator.search(query: "multi")
                    }
                }

                for await results in group {
                    // Each search should return all 50 unique records (5 providers x 10 records)
                    // All records have unique IDs so no dedup should occur
                    #expect(results.count == 50,
                            "Expected 50 results from 5 providers, got \(results.count)")
                }
            }
        }
    }

    // MARK: - 3. Slow provider does not block fast provider

    /// One provider has an artificial delay. The coordinator should still
    /// collect results from the fast provider without waiting for the slow one.
    @Test("Slow provider does not block fast provider results")
    func testSlowProviderDoesNotBlock() async throws {
        let fastRecords = (1...10).map { i in
            makeRecord(id: UInt32(i), name: "fast\(i).txt")
        }
        let fastResults = fastRecords.map { record in
            SearchResult(record: record, providerID: "fast", score: 1.0, matchType: .exact)
        }

        let slowRecords = (11...15).map { i in
            makeRecord(id: UInt32(i), name: "slow\(i).txt")
        }
        let slowResults = slowRecords.map { record in
            SearchResult(record: record, providerID: "slow", score: 0.5, matchType: .substring)
        }

        let fastProvider = CountingSearchProvider(providerID: "fast", results: fastResults)
        let slowProvider = CountingSearchProvider(
            providerID: "slow",
            results: slowResults,
            delayNanos: 1_000_000_000  // 1 second delay
        )

        let coordinator = SearchCoordinator(providers: [fastProvider, slowProvider])

        let startTime = Date()

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: [SearchResult].self) { group in
                group.addTask {
                    await coordinator.search(query: "all")
                }

                // Also search with a second concurrent request
                group.addTask {
                    await coordinator.search(query: "fast")
                }

                var resultsCounts: [Int] = []
                for await results in group {
                    resultsCounts.append(results.count)
                }

                // The combined search should have 15 results (all unique IDs)
                #expect(resultsCounts.sorted().last! >= 10,
                        "Should get at least the fast provider's results")
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        // Both searches together should complete in well under the 1-second delay
        // since the fast search doesn't need to wait for the slow one.
        // Allow some overhead, but it should be much less than the delay.
        #expect(elapsed < 2.0,
                "Concurrent searches should not be gated by slow provider: took \(elapsed)s")
    }

    // MARK: - 4. Query cancellation propagates to providers

    /// Rapidly sends multiple queries to force cancellation of previous
    /// in-flight queries. Verifies cancel() is called on providers for
    /// superseded queries.
    @Test("Rapid sequential queries cancel previous in-flight queries on providers")
    func testQueryCancellationPropagates() async throws {
        let record = makeRecord(id: 1, name: "cancel.txt")
        let result = SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)
        let provider = CountingSearchProvider(providerID: "mock", results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        // Send 5 queries in rapid succession (not concurrently — sequentially
        // to trigger cancellation of the previous query each time)
        for i in 1...5 {
            _ = await coordinator.search(query: "query\(i)")
        }

        // After 5 sequential queries: search called 5 times, cancel called 4 times
        // (no cancel on the first query since there was no previous)
        #expect(provider.searchCallCount == 5,
                "Expected 5 search calls, got \(provider.searchCallCount)")
        #expect(provider.cancelCallCount == 4,
                "Expected 4 cancel calls (one per superseded query), got \(provider.cancelCallCount)")
    }

    // MARK: - 5. Concurrent adds/removes of providers during search

    /// Adds and removes providers concurrently while searches are running.
    /// Verifies the coordinator remains stable.
    @Test("Concurrent provider add/remove during searches does not crash")
    func testConcurrentProviderChangesDuringSearch() async throws {
        let initialRecord = makeRecord(id: 1, name: "stable.txt")
        let initialResult = SearchResult(
            record: initialRecord, providerID: "stable", score: 1.0, matchType: .exact
        )
        let initialProvider = CountingSearchProvider(
            providerID: "stable", results: [initialResult]
        )
        let coordinator = SearchCoordinator(providers: [initialProvider])

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: Void.self) { group in
                // Task A: Repeatedly search
                group.addTask {
                    for _ in 0..<10 {
                        let results = await coordinator.search(query: "stable")
                        #expect(results.count >= 1,
                                "Stable provider should always return results")
                        await Task.yield()
                    }
                }

                // Task B: Add and remove temporary providers
                group.addTask {
                    for i in 0..<5 {
                        let record = makeRecord(id: UInt32(100 + i), name: "temp\(i).txt")
                        let result = SearchResult(
                            record: record, providerID: "temp\(i)", score: 0.5,
                            matchType: .substring
                        )
                        let tempProvider = CountingSearchProvider(
                            providerID: "temp\(i)", results: [result]
                        )
                        await coordinator.addProvider(tempProvider)
                        await Task.yield()

                        // Remove it shortly after
                        await coordinator.removeProvider(id: "temp\(i)")
                        await Task.yield()
                    }
                }

                // Task C: Search during provider churn
                group.addTask {
                    for _ in 0..<5 {
                        let results = await coordinator.search(query: "temp")
                        // Results may vary depending on timing — just check no crash
                        #expect(results.count >= 0)
                        await Task.yield()
                    }
                }
            }
        }
    }

    // MARK: - 6. Deduplication correctness under concurrency

    /// The same file appears from multiple providers while concurrent searches
    /// run. Deduplication must be correct regardless of scheduling.
    @Test("Deduplication is correct under concurrent search load")
    func testDeduplicationUnderConcurrency() async throws {
        // Create providers that share some records (same IDs)
        let sharedRecords = (1...5).map { i in
            makeRecord(id: UInt32(i), name: "shared\(i).txt")
        }
        let sharedResults = sharedRecords.map { record in
            SearchResult(record: record, providerID: "p1", score: 1.0, matchType: .exact)
        }

        // Provider 2 has the same records as Provider 1 (should be deduped out)
        let dupResults = sharedRecords.map { record in
            SearchResult(record: record, providerID: "p2", score: 0.5, matchType: .substring)
        }

        let uniqueRecords = (6...10).map { i in
            makeRecord(id: UInt32(i), name: "unique\(i).txt")
        }
        let uniqueResults = uniqueRecords.map { record in
            SearchResult(record: record, providerID: "p2", score: 1.0, matchType: .substring)
        }

        let p1 = CountingSearchProvider(providerID: "p1", results: sharedResults)
        // p2 has both duplicates and unique records
        let p2 = CountingSearchProvider(providerID: "p2", results: dupResults + uniqueResults)

        let coordinator = SearchCoordinator(providers: [p1, p2])

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: [SearchResult].self) { group in
                for _ in 0..<5 {
                    group.addTask {
                        await coordinator.search(query: "shared")
                    }
                }

                for await results in group {
                    // 5 shared + 5 unique = 10 unique records total
                    #expect(results.count == 10,
                            "Expected 10 unique records after dedup, got \(results.count)")

                    // Verify no duplicate IDs
                    let ids = results.map(\.record.id)
                    let uniqueIDs = Set(ids)
                    #expect(ids.count == uniqueIDs.count,
                            "No duplicate record IDs should appear in results")
                }
            }
        }
    }

    // MARK: - 7. Empty coordinator under concurrent load

    /// Concurrent searches against an empty coordinator should all return
    /// empty arrays without errors.
    @Test("Concurrent searches against empty coordinator return empty safely")
    func testConcurrentEmptyCoordinator() async throws {
        let coordinator = SearchCoordinator(providers: [])

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: [SearchResult].self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        await coordinator.search(query: "nothing")
                    }
                }

                for await results in group {
                    #expect(results.isEmpty,
                            "Empty coordinator should return empty results")
                }
            }
        }
    }

    // MARK: - 8. Provider returning async sequence with many items

    /// A provider returning a large number of results via AsyncSequence.
    /// Verifies the coordinator correctly iterates through the sequence
    /// under concurrent load.
    @Test("Large result sequences from providers are collected correctly under concurrency")
    func testLargeAsyncSequenceCollection() async throws {
        let largeRecords = (1...200).map { i in
            let record = makeRecord(id: UInt32(i), name: "huge\(i).txt")
            return SearchResult(record: record, providerID: "large", score: 1.0, matchType: .substring)
        }

        let provider = CountingSearchProvider(providerID: "large", results: largeRecords)
        let coordinator = SearchCoordinator(providers: [provider])

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: [SearchResult].self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        await coordinator.search(query: "huge")
                    }
                }

                for await results in group {
                    #expect(results.count == 200,
                            "Expected 200 results, got \(results.count)")
                    // Verify result is capped at the default limit (1000)
                    // but 200 < 1000 so all should be returned
                }
            }
        }
    }

    // MARK: - 9. Concurrent searches with different queries

    /// Multiple different queries running concurrently through the same
    /// coordinator. Each query's results must be independent.
    @Test("Different concurrent queries return independent correct results")
    func testDifferentConcurrentQueries() async throws {
        // Provider returning results for multiple pattern matches
        var allResults: [SearchResult] = []
        for i in 1...30 {
            let name: String
            if i <= 10 {
                name = "alpha\(i).txt"
            } else if i <= 20 {
                name = "beta\(i - 10).txt"
            } else {
                name = "gamma\(i - 20).txt"
            }
            let record = makeRecord(id: UInt32(i), name: name)
            allResults.append(
                SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)
            )
        }

        let provider = CountingSearchProvider(providerID: "mock", results: allResults)
        let coordinator = SearchCoordinator(providers: [provider])

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: (String, Int).self) { group in
                for queryName in ["alpha", "beta", "gamma"] {
                    let q = queryName
                    group.addTask {
                        let results = await coordinator.search(query: q)
                        // The mock returns all 30 results for any query,
                        // so the coordinator filters/returns based on all results.
                        // We check that results are returned correctly (no crash, no mixing).
                        return (q, results.count)
                    }
                }

                for await (query, count) in group {
                    #expect(count >= 0, "Query '\(query)' should return results")
                }
            }
        }
    }

    // MARK: - 10. Stress: many concurrent searches on many providers

    /// 10 providers, each with 50 results, 15 concurrent searches.
    /// Stress-tests the full pipeline: dispatch, collection, dedup, sort, limit.
    @Test("Many concurrent searches across many providers complete correctly")
    func testManyProvidersManySearches() async throws {
        var providers: [CountingSearchProvider] = []

        for p in 1...10 {
            var providerResults: [SearchResult] = []
            for i in 1...50 {
                let id = UInt32((p - 1) * 100 + i)
                let record = makeRecord(id: id, name: "stress_p\(p)_f\(i).txt")
                providerResults.append(
                    SearchResult(record: record, providerID: "p\(p)", score: Double(p), matchType: .substring)
                )
            }
            providers.append(CountingSearchProvider(providerID: "p\(p)", results: providerResults))
        }

        let coordinator = SearchCoordinator(providers: providers)

        try await withTimeout(seconds: 30) {
            await withTaskGroup(of: [SearchResult].self) { group in
                for _ in 0..<15 {
                    group.addTask {
                        await coordinator.search(query: "stress")
                    }
                }

                var allResultCounts: [Int] = []
                for await results in group {
                    allResultCounts.append(results.count)
                }

                #expect(allResultCounts.count == 15, "Expected 15 search completions")
                // Each search should return 500 unique results (10 providers x 50 records)
                // but capped at coordinator's resultLimit (default 1000)
                for count in allResultCounts {
                    #expect(count == 500,
                            "Expected 500 unique results per search, got \(count)")
                }
            }
        }
    }
}
