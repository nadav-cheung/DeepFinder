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
        let raw = query.rawQuery

        // Wildcard pattern (glob with `*`/`?`): scan all records and apply
        // PatternMatcher — the index has no structural support for glob matching.
        // Explicit wildcard queries are rare, so an O(n) in-memory scan (capped at
        // maxResults) is acceptable; the index stays sub-millisecond for normal queries.
        if raw.contains("*") || raw.contains("?") {
            return await patternSearch(pattern: raw) { record in
                PatternMatcher.matchWildcard(pattern: raw, input: record.name)
            }
        }

        // Regex pattern (`regex:` prefix).
        if raw.hasPrefix("regex:") {
            let pattern = String(raw.dropFirst("regex:".count))
            return await patternSearch(pattern: pattern) { record in
                PatternMatcher.matchRegex(pattern: pattern, input: record.name)
            }
        }

        guard !query.normalizedQuery.isEmpty else { return [] }

        let records = await index.searchSubstring(query: query.normalizedQuery)

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

    /// Scan all indexed records, keeping those that `matcher` accepts, capped at
    /// `Constants.Daemon.maxResults`. Used for wildcard/regex queries.
    private func patternSearch(
        pattern: String,
        matcher: @Sendable @escaping (FileRecord) -> Bool
    ) async -> [SearchResult] {
        guard !pattern.isEmpty else { return [] }
        let allRecords = await index.allRecords()
        var results: [SearchResult] = []
        let cap = Constants.Daemon.maxResults
        for record in allRecords {
            guard matcher(record) else { continue }
            // Wildcard/regex matches classify as substring (no dedicated MatchType),
            // scored slightly above a plain substring hit — it was an explicit pattern.
            results.append(SearchResult(
                record: record,
                providerID: providerID,
                score: 0.6,
                matchType: .substring
            ))
            if results.count >= cap { break }
        }
        return results
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
