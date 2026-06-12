// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex

// MARK: - FileIndexProvider

/// MVP search provider that wraps `InMemoryIndex`.
///
/// Searches are delegated to the index actor; results are classified by
/// `MatchType` (exact / prefix / substring) and assigned a fixed score.
/// All results are yielded at once — no streaming.
public actor FileIndexProvider: SearchProvider {

    // MARK: - Properties

    public let providerID = "file-index"

    private let index: InMemoryIndex

    // MARK: - Init

    /// Create a file-index provider wrapping the given in-memory index.
    ///
    /// - Parameter index: The index actor to delegate searches to.
    public init(index: InMemoryIndex) {
        self.index = index
    }

    // MARK: - SearchProvider

    public func search(query: SearchQuery) async -> SearchResultSequence {
        let results = await performSearch(query: query)
        return SearchResultSequence(results)
    }

    public func cancel(queryID: String) async {
        // MVP: synchronous search completes instantly, nothing to cancel.
    }

    public func prepare() async {
        // In-memory index is always ready. No-op.
    }

    // MARK: - Internal

    private func performSearch(query: SearchQuery) async -> [SearchResult] {
        guard !query.normalizedQuery.isEmpty else { return [] }

        let records = await index.search(query: query.normalizedQuery)

        return records.map { record in
            let (matchType, score) = classifyMatch(
                normalizedQuery: query.normalizedQuery,
                recordName: record.name
            )
            return SearchResult(
                record: record,
                providerID: providerID,
                score: score,
                matchType: matchType
            )
        }
    }

    /// Determine how the query matched the record name and assign a score.
    ///
    /// Classification order matters: exact is checked before prefix,
    /// prefix before substring. Both sides are NFC-normalized and lowercased.
    private func classifyMatch(normalizedQuery: String, recordName: String) -> (MatchType, Double) {
        let normalized = recordName.precomposedStringWithCanonicalMapping.lowercased()

        if normalized == normalizedQuery {
            return (.exact, 1.0)
        }
        if normalized.hasPrefix(normalizedQuery) {
            return (.prefix, 0.8)
        }
        return (.substring, 0.5)
    }
}
