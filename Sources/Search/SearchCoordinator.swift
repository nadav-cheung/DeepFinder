import Foundation

// MARK: - SearchCoordinator

/// Orchestrates search across multiple providers.
///
/// Dispatches queries to all registered providers concurrently, collects and
/// deduplicates results, sorts by relevance, and returns the final list.
///
/// Thread-safe via actor isolation. NOT `@MainActor` — works in both daemon
/// and future GUI contexts.
actor SearchCoordinator {

    // MARK: - Properties

    private var providers: [any SearchProvider] = []
    private var querySequenceNumber: UInt64 = 0
    private var lastQueryID: String?
    private let resultLimit: Int

    /// Timeout per provider in seconds. Stored for future streaming providers.
    /// MVP providers are synchronous and always complete instantly.
    var providerTimeout: TimeInterval = 5.0

    // MARK: - Init

    init(providers: [any SearchProvider], resultLimit: Int = 1000) {
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
    /// - Sorts by relevance.
    /// - Returns results capped at `resultLimit`.
    func search(query rawQuery: String) async -> [SearchResult] {
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

        // Sort by relevance
        let sorted = SearchSorter.sort(deduplicated, by: .relevance)

        // Cap at resultLimit
        return Array(sorted.prefix(resultLimit))
    }

    /// Add a provider at runtime.
    func addProvider(_ provider: any SearchProvider) {
        providers.append(provider)
    }

    /// Remove a provider by its ID.
    func removeProvider(id: String) {
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
