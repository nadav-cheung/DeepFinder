import Foundation

// MARK: - SortCriterion

/// Criterion for sorting search results.
enum SortCriterion: Sendable {
    case relevance
    case name
    case date
    case size
}

// MARK: - SearchSorter

/// Stateless sorter for search results. All methods are static; no instance needed.
struct SearchSorter: Sendable {

    /// Sort results according to the given criterion.
    static func sort(_ results: [SearchResult], by criterion: SortCriterion) -> [SearchResult] {
        switch criterion {
        case .relevance:
            results.sorted(by: relevanceOrder)
        case .name:
            results.sorted { $0.record.name.localizedStandardCompare($1.record.name) == .orderedAscending }
        case .date:
            results.sorted { $0.record.modifiedAt > $1.record.modifiedAt }
        case .size:
            results.sorted { $0.record.size > $1.record.size }
        }
    }

    /// Count the number of path components (separators + 1 for non-empty paths).
    static func pathDepth(_ path: String) -> Int {
        guard !path.isEmpty else { return 0 }
        return path.filter { $0 == "/" }.count
    }

    // MARK: - Private

    /// Relevance ordering:
    /// 1. MatchType (lower rawValue = higher priority)
    /// 2. Filename length (shorter first)
    /// 3. modifiedAt (newer first)
    /// 4. Path depth (shallower first)
    /// 5. FileRecord.ID (lower first, stable tiebreak)
    private static func relevanceOrder(_ a: SearchResult, _ b: SearchResult) -> Bool {
        // 1. MatchType priority
        if a.matchType != b.matchType {
            return a.matchType < b.matchType
        }
        // 2. Shorter filename first
        let aLen = a.record.name.count
        let bLen = b.record.name.count
        if aLen != bLen {
            return aLen < bLen
        }
        // 3. Newer date first
        if a.record.modifiedAt != b.record.modifiedAt {
            return a.record.modifiedAt > b.record.modifiedAt
        }
        // 4. Shallower path first
        let aDepth = pathDepth(a.record.path)
        let bDepth = pathDepth(b.record.path)
        if aDepth != bDepth {
            return aDepth < bDepth
        }
        // 5. Stable tiebreak by ID
        return a.record.id < b.record.id
    }
}
