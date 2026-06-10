import Foundation
import Testing
import DeepFinderAI
import DeepFinderPersist
import DeepFinderIndex
@testable import DeepFinderSearch

@Suite("SearchCoordinator")
struct SearchCoordinatorTests {

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
    /// If resultsClosure is set, it is used; otherwise `fixedResults` is returned.
    private final class MockSearchProvider: SearchProvider, @unchecked Sendable {
        let providerID: String
        var fixedResults: [SearchResult]
        var resultsClosure: ((SearchQuery) -> [SearchResult])?
        private(set) var cancelCallCount: Int = 0
        private(set) var lastCancelledQueryID: String?
        private(set) var searchCallCount: Int = 0

        init(providerID: String, results: [SearchResult] = []) {
            self.providerID = providerID
            self.fixedResults = results
        }

        func search(query: SearchQuery) async -> SearchResultSequence {
            searchCallCount += 1
            let results = resultsClosure?(query) ?? fixedResults
            return SearchResultSequence(results)
        }

        func cancel(queryID: String) async {
            cancelCallCount += 1
            lastCancelledQueryID = queryID
        }

        func prepare() async {}
    }

    /// Build a coordinator with the given mock providers.
    private func makeCoordinator(providers: [MockSearchProvider]) -> SearchCoordinator {
        SearchCoordinator(providers: providers)
    }

    // MARK: - Basic search

    @Test("Basic search returns results")
    func testSearchReturnsResults() async {
        let record = makeRecord(id: 1, name: "report.pdf")
        let provider = MockSearchProvider(
            providerID: "mock",
            results: [SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)]
        )
        let coordinator = makeCoordinator(providers: [provider])

        let results = await coordinator.search(query: "report.pdf")
        #expect(results.count == 1)
        #expect(results[0].record.name == "report.pdf")
    }

    @Test("Case-insensitive search")
    func testSearchCaseInsensitive() async {
        // "REPORT" should find "report.pdf" because SearchQuery normalizes to lowercase
        let record = makeRecord(id: 1, name: "report.pdf")
        let provider = MockSearchProvider(
            providerID: "mock",
            results: [SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)]
        )
        // The mock returns the same results regardless of query text; the coordinator
        // passes a SearchQuery (which lowercases) to the provider.
        // We verify the coordinator dispatches correctly and returns results.
        let coordinator = makeCoordinator(providers: [provider])

        let results = await coordinator.search(query: "REPORT")
        #expect(results.count == 1)
        #expect(results[0].record.name == "report.pdf")
    }

    // MARK: - Deduplication

    @Test("Deduplicates results across providers")
    func testSearchDeduplicatesResults() async {
        let record = makeRecord(id: 1, name: "report.pdf")

        let providerA = MockSearchProvider(
            providerID: "a",
            results: [SearchResult(record: record, providerID: "a", score: 0.5, matchType: .substring)]
        )
        let providerB = MockSearchProvider(
            providerID: "b",
            results: [SearchResult(record: record, providerID: "b", score: 1.0, matchType: .exact)]
        )

        let coordinator = makeCoordinator(providers: [providerA, providerB])
        let results = await coordinator.search(query: "report")

        // Same file from two providers: deduplicated to one result
        #expect(results.count == 1)
        // The exact match (higher priority) wins
        #expect(results[0].matchType == .exact)
    }

    // MARK: - Sorting

    @Test("Results sorted by relevance")
    func testSearchSortedByRelevance() async {
        let exact = makeRecord(id: 1, name: "report.pdf")
        let prefix = makeRecord(id: 2, name: "report-2024.xlsx")
        let substring = makeRecord(id: 3, name: "quarterly-report.txt")

        let provider = MockSearchProvider(
            providerID: "mock",
            results: [
                SearchResult(record: substring, providerID: "mock", score: 0.5, matchType: .substring),
                SearchResult(record: prefix, providerID: "mock", score: 0.8, matchType: .prefix),
                SearchResult(record: exact, providerID: "mock", score: 1.0, matchType: .exact),
            ]
        )
        let coordinator = makeCoordinator(providers: [provider])

        let results = await coordinator.search(query: "report")
        #expect(results.count == 3)
        // Exact first, then prefix, then substring
        #expect(results[0].matchType == .exact)
        #expect(results[1].matchType == .prefix)
        #expect(results[2].matchType == .substring)
    }

    // MARK: - Edge cases

    @Test("Empty query returns empty results")
    func testEmptyQueryReturnsEmpty() async {
        let record = makeRecord(id: 1, name: "report.pdf")
        let provider = MockSearchProvider(
            providerID: "mock",
            results: [SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)]
        )
        let coordinator = makeCoordinator(providers: [provider])

        let results = await coordinator.search(query: "")
        #expect(results.isEmpty)
    }

    @Test("No providers returns empty results")
    func testNoProvidersReturnsEmpty() async {
        let coordinator = makeCoordinator(providers: [])
        let results = await coordinator.search(query: "report")
        #expect(results.isEmpty)
    }

    // MARK: - Dynamic provider management

    @Test("Add provider at runtime")
    func testAddProviderDynamic() async {
        let coordinator = makeCoordinator(providers: [])

        // Initially no results
        var results = await coordinator.search(query: "report")
        #expect(results.isEmpty)

        // Add a provider
        let record = makeRecord(id: 1, name: "report.pdf")
        let provider = MockSearchProvider(
            providerID: "mock",
            results: [SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)]
        )
        await coordinator.addProvider(provider)

        results = await coordinator.search(query: "report")
        #expect(results.count == 1)
    }

    @Test("Remove provider by ID")
    func testRemoveProvider() async {
        let record = makeRecord(id: 1, name: "report.pdf")
        let provider = MockSearchProvider(
            providerID: "mock",
            results: [SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .exact)]
        )
        let coordinator = makeCoordinator(providers: [provider])

        // Results present
        var results = await coordinator.search(query: "report")
        #expect(results.count == 1)

        // Remove the provider
        await coordinator.removeProvider(id: "mock")

        // No results now
        results = await coordinator.search(query: "report")
        #expect(results.isEmpty)
    }

    // MARK: - Query sequence numbering

    @Test("Query sequence number increments with each search")
    func testQuerySequenceIncrements() async {
        let provider = MockSearchProvider(providerID: "mock", results: [])
        let coordinator = makeCoordinator(providers: [provider])

        _ = await coordinator.search(query: "a")
        _ = await coordinator.search(query: "b")
        _ = await coordinator.search(query: "c")

        // The mock's search was called 3 times
        #expect(provider.searchCallCount == 3)

        // The cancel should have been called for the previous query (cancel is called
        // on each provider for the previous queryID before dispatching the new one).
        // After 3 searches: cancel called twice (before query 2 and query 3).
        #expect(provider.cancelCallCount == 2)
    }

    // MARK: - Result limit

    @Test("Results capped at configured limit")
    func testSearchResultLimit() async {
        // Create 5 records
        let records = (1...5).map { i in
            makeRecord(id: UInt32(i), name: "file\(i).txt")
        }
        let results = records.enumerated().map { (i, record) in
            SearchResult(record: record, providerID: "mock", score: 1.0, matchType: .substring)
        }

        let provider = MockSearchProvider(providerID: "mock", results: results)
        let coordinator = SearchCoordinator(providers: [provider], resultLimit: 3)

        let found = await coordinator.search(query: "file")
        #expect(found.count == 3)
    }
}
