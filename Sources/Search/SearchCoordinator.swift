/// # Search Module
///
/// The query processing pipeline: parsing, filtering, sorting, and result delivery.
///
/// ## Components
/// - ``SearchCoordinator`` -- actor that orchestrates search across multiple providers
/// - ``SearchProvider`` -- protocol for search backends (file index, content, AI)
/// - ``FileIndexProvider`` -- MVP provider wrapping ``InMemoryIndex``
/// - ``ContentSearchProvider`` -- full-text file content search
/// - ``SearchQuery`` / ``SearchResult`` / ``MatchType`` -- core search types
/// - ``QueryTerm`` / ``QueryParser`` -- query AST and recursive descent parser
/// - ``SearchFilter`` / ``FilterPipeline`` -- size, date, extension, metadata filters
/// - ``SearchSorter`` -- relevance, name, date, size, natural sort
/// - ``PatternMatcher`` -- wildcard and regex matching against file names
/// - ``AutocompleteProvider`` -- prefix-based query suggestions
/// - ``SearchBookmark`` -- saved searches for quick access
/// - ``ContentScanner`` -- file content reading and line-level matching
/// - ``DuplicateFinder`` / ``FileHasher`` -- duplicate file detection
/// - ``SearchTypes`` -- shared type definitions
///
/// ## Query Pipeline
/// ```
/// Raw query -> QueryParser -> SearchFilter[] + text
///          -> SearchCoordinator -> providers (concurrent)
///          -> deduplicate -> FilterPipeline -> SearchSorter -> results
/// ```
///
/// ## Query Syntax
/// - Plain text: `deepfinder report`
/// - Boolean: `report !draft`, `report | memo`
/// - Wildcards: `*.pdf`, `report_?.txt`
/// - Regex: `regex:^report_\d{4}`
/// - Modifiers: `ext:pdf`, `size:>10mb`, `dm:today`, `file:`, `folder:`
/// - Path qualifier: `Projects\ report` (backslash-space)
import Foundation
import DeepFinderIndex

// MARK: - SearchCoordinator

/// Orchestrates search across multiple providers.
///
/// Dispatches queries to all registered providers concurrently, collects and
/// deduplicates results, sorts by relevance, and returns the final list.
///
/// Thread-safe via actor isolation. NOT `@MainActor` — works in both daemon
/// and future GUI contexts.
public actor SearchCoordinator {

    // MARK: - Properties

    private var providers: [any SearchProvider] = []
    private var querySequenceNumber: UInt64 = 0
    private var lastQueryID: String?
    private let resultLimit: Int

    // MARK: - Init

    /// Create a coordinator with the given providers and result cap.
    ///
    /// - Parameters:
    ///   - providers: Search backends to dispatch queries to.
    ///   - resultLimit: Maximum number of results returned per query. Default 1000.
    public init(providers: [any SearchProvider], resultLimit: Int = Constants.Daemon.maxResults) {
        self.providers = providers
        self.resultLimit = resultLimit
    }

    // MARK: - Public API

    /// Execute a search across all providers.
    ///
    /// - Creates a `SearchQuery` from the raw string.
    /// - Cancels the previous in-flight query on all providers.
    /// - Dispatches to all providers concurrently.
    /// - Deduplicates by `FileRecord.id` (keeps highest-priority match).
    /// - Applies `FilterPipeline` to remove non-matching results.
    /// - Sorts by relevance.
    /// - Returns results capped at `resultLimit`.
    public func search(query rawQuery: String, filters: [SearchFilter] = []) async -> [SearchResult] {
        // Empty query shortcut
        guard !rawQuery.isEmpty else { return [] }
        guard !providers.isEmpty else { return [] }

        let query = SearchQuery(rawQuery)

        // Increment sequence number and build a stable query ID
        querySequenceNumber += 1
        let queryID = "q\(querySequenceNumber)"

        // Cancel previous query on all providers
        if let previousID = lastQueryID {
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask {
                        await provider.cancel(queryID: previousID)
                    }
                }
            }
        }
        lastQueryID = queryID

        // Dispatch to all providers concurrently and collect results
        let allResults = await withTaskGroup(of: [SearchResult].self) { group in
            for provider in providers {
                group.addTask {
                    let sequence = await provider.search(query: query)
                    var results: [SearchResult] = []
                    for await result in sequence {
                        results.append(result)
                    }
                    return results
                }
            }

            var combined: [SearchResult] = []
            for await providerResults in group {
                combined.append(contentsOf: providerResults)
            }
            return combined
        }

        // Deduplicate by FileRecord.id: keep highest-priority match
        let deduplicated = deduplicate(allResults)

        // Apply filters (AND semantics: all filters must match)
        let pipeline = FilterPipeline(filters: filters)
        let filtered = pipeline.apply(to: deduplicated)

        // Sort by relevance
        let sorted = SearchSorter.sort(filtered, by: .relevance)

        // Cap at resultLimit
        return Array(sorted.prefix(resultLimit))
    }

    /// Add a provider at runtime.
    public func addProvider(_ provider: any SearchProvider) {
        providers.append(provider)
    }

    /// Remove a provider by its ID.
    public func removeProvider(id: String) {
        providers.removeAll { $0.providerID == id }
    }

    // MARK: - Private

    /// Deduplicate results by FileRecord.id.
    /// When the same file appears from multiple providers, keep the one with
    /// the highest-priority match (lower MatchType rawValue wins). If match
    /// types are equal, keep the higher score.
    private func deduplicate(_ results: [SearchResult]) -> [SearchResult] {
        var best: [UInt32: SearchResult] = [:]
        for result in results {
            let fileID = result.record.id
            if let existing = best[fileID] {
                // Keep the better match: MatchType priority first, then score
                if result.matchType < existing.matchType {
                    best[fileID] = result
                } else if result.matchType == existing.matchType && result.score > existing.score {
                    best[fileID] = result
                }
            } else {
                best[fileID] = result
            }
        }
        return Array(best.values)
    }
}
