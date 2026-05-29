import Foundation

// MARK: - SearchResultSequence

/// A Sendable `AsyncSequence` of search results. All providers return this
/// concrete type so that results can safely cross actor boundaries
/// (the existential `any AsyncSequence` is not `Sendable`).
struct SearchResultSequence: AsyncSequence, Sendable {
    typealias Element = SearchResult
    typealias AsyncIterator = Iterator

    private let elements: [SearchResult]

    init(_ elements: [SearchResult]) {
        self.elements = elements
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(iterator: elements.makeIterator())
    }

    struct Iterator: AsyncIteratorProtocol, Sendable {
        var iterator: Array<SearchResult>.Iterator

        mutating func next() async -> SearchResult? {
            iterator.next()
        }
    }
}

// MARK: - SearchProvider

/// A provider that can execute searches and return results asynchronously.
///
/// Providers are the unit of extensibility for search: different providers
/// can search different data sources (in-memory index, content search, AI, etc.)
/// while sharing the same `SearchQuery` / `SearchResult` types.
///
/// MVP has a single provider (`FileIndexProvider`); the protocol exists so
/// future providers (content search, AI semantic search) can be added
/// without modifying the coordinator.
protocol SearchProvider: Sendable {
    /// Stable identifier for this provider (e.g. "file-index", "content-search").
    var providerID: String { get }

    /// Execute a search. Results are returned as a `SearchResultSequence`
    /// (a Sendable AsyncSequence). MVP providers yield all results at once;
    /// future streaming providers can yield incrementally.
    func search(query: SearchQuery) async -> SearchResultSequence

    /// Cancel an in-flight query. MVP is synchronous — this is a no-op,
    /// but the protocol must declare it for future streaming providers.
    func cancel(queryID: String) async

    /// One-time async setup (e.g. loading an index from disk).
    /// Called once before the first search. No-op for in-memory providers.
    func prepare() async
}
