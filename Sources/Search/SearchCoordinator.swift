// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

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

    // MARK: - Boolean AST Search

    /// Execute a search driven by a boolean AST (REQ-1.1-02, REQ-1.1-04).
    ///
    /// Used when the parsed query contains `.or` or `.not` nodes – leaf text
    /// terms are searched individually, then combined with set operations.
    /// For simple queries without boolean operators, the existing
    /// ``search(query:filters:)`` fast path is preferred.
    ///
    /// - Parameters:
    ///   - parsed: The parsed query AST (from `QueryParser.parse`).
    ///   - filters: Metadata filters extracted from modifier terms.
    /// - Returns: Sorted, deduplicated results capped at `resultLimit`.
    public func searchWithBooleanAST(
        parsed: ParsedQuery,
        filters: [SearchFilter]
    ) async -> [SearchResult] {
        guard !providers.isEmpty else { return [] }

        // Increment sequence number – cancels previous query
        querySequenceNumber += 1
        let queryID = "bq\(querySequenceNumber)"
        if let previousID = lastQueryID {
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask { await provider.cancel(queryID: previousID) }
                }
            }
        }
        lastQueryID = queryID

        // Evaluate the AST
        let rawResults = await evaluateTerms(parsed.terms)

        // Deduplicate, filter, sort
        let deduped = deduplicate(rawResults)
        let pipeline = FilterPipeline(filters: filters)
        let filtered = pipeline.apply(to: deduped)
        let sorted = SearchSorter.sort(filtered, by: .relevance)
        return Array(sorted.prefix(resultLimit))
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

    // MARK: Boolean AST Evaluation

    /// AND-combine the results of multiple AST terms.
    /// Negative (`.not`) sub-terms are subtracted from the positive intersection.
    private func evaluateTerms(_ terms: [QueryTerm]) async -> [SearchResult] {
        guard !terms.isEmpty else { return [] }

        // Separate positive and negative terms at the top level.
        // For `swift !test`, terms = [.text("swift"), .not(.text("test"))]
        // → positives = [.text("swift")], negatives = [.text("test")]
        let positiveTerms = terms.filter { if case .not = $0 { false } else { true } }
        let negativeTerms = terms.compactMap { if case .not(let inner) = $0 { inner } else { nil } }

        // Evaluate positives with AND semantics
        var positives: [SearchResult] = []
        for (i, pt) in positiveTerms.enumerated() {
            let res = await evaluateTerm(pt)
            if i == 0 {
                positives = res
            } else {
                let ids = Set(res.map(\.record.id))
                positives = positives.filter { ids.contains($0.record.id) }
            }
        }

        // Subtract negatives
        for nt in negativeTerms {
            let neg = await evaluateTerm(nt)
            let negIDs = Set(neg.map(\.record.id))
            positives = positives.filter { !negIDs.contains($0.record.id) }
        }

        return positives
    }

    /// Recursively evaluate a single QueryTerm node.
    private func evaluateTerm(_ term: QueryTerm) async -> [SearchResult] {
        switch term {
        case .and(let sub):
            return await evaluateTerms(sub)

        case .or(let sub):
            var all: [SearchResult] = []
            for t in sub {
                all += await evaluateTerm(t)
            }
            return all

        case .not:
            // Standalone NOT without AND context — cannot subtract from anything.
            return []

        case .text(let s):
            return await searchLeaf(query: s)

        case .wildcard(let pattern):
            return await searchLeaf(query: pattern)

        case .regex(let pattern):
            return await searchLeaf(query: "regex:\(pattern)")

        case .modifier, .pathQualifier:
            // Modifiers are extracted as filters elsewhere; path qualifiers are
            // not yet supported at the AST level.
            return []
        }
    }

    /// Run a single leaf-term search across all providers.
    /// Each leaf is an independent `SearchQuery` dispatch.
    private func searchLeaf(query rawQuery: String) async -> [SearchResult] {
        guard !rawQuery.isEmpty else { return [] }
        let query = SearchQuery(rawQuery)

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

        return allResults
    }
}
