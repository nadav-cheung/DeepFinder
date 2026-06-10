import Foundation
import DeepFinderIndex

// MARK: - SortCriterion

/// Criterion for sorting search results.
public enum SortCriterion: Sendable {
    /// Sort by match type priority, then filename length, then recency, then path depth.
    case relevance
    /// Sort alphabetically by filename using locale-aware comparison.
    case name
    /// Sort by modification date (newest first).
    case date
    /// Sort by file size (largest first).
    case size
    /// Sort using natural (human-friendly) comparison (e.g. "file2" before "file10").
    case natural
}

// MARK: - SearchSorter

/// Stateless sorter for search results. All methods are static; no instance needed.
public struct SearchSorter: Sendable {

    /// Prevent instantiation — all API is static.
    private init() {}

    /// Sort results according to the given criterion.
    public static func sort(_ results: [SearchResult], by criterion: SortCriterion) -> [SearchResult] {
        switch criterion {
        case .relevance:
            results.sorted(by: relevanceOrder)
        case .name:
            results.sorted { $0.record.name.localizedStandardCompare($1.record.name) == .orderedAscending }
        case .date:
            results.sorted { $0.record.modifiedAt > $1.record.modifiedAt }
        case .size:
            results.sorted { $0.record.size > $1.record.size }
        case .natural:
            results.sorted { naturalCompare($0.record.name, $1.record.name) }
        }
    }

    /// Natural (human-friendly) string comparison.
    /// Splits strings into numeric and non-numeric segments; compares numeric
    /// segments by integer value, non-numeric segments lexicographically.
    /// Both inputs are NFC-normalized before comparison.
    ///
    /// Returns `true` when `a` should appear before `b`.
    public static func naturalCompare(_ a: String, _ b: String) -> Bool {
        let aNorm = a.precomposedStringWithCanonicalMapping
        let bNorm = b.precomposedStringWithCanonicalMapping

        var aIdx = aNorm.startIndex
        var bIdx = bNorm.startIndex
        let aEnd = aNorm.endIndex
        let bEnd = bNorm.endIndex

        while aIdx < aEnd && bIdx < bEnd {
            let aChar = aNorm[aIdx]
            let bChar = bNorm[bIdx]
            let aIsDigit = aChar.isNumber
            let bIsDigit = bChar.isNumber

            if aIsDigit && bIsDigit {
                // Both numeric: extract full digit runs and compare as integers
                let aNum = extractNumber(aNorm, from: &aIdx)
                let bNum = extractNumber(bNorm, from: &bIdx)
                if aNum != bNum {
                    return aNum < bNum
                }
                // Equal numbers — continue to next segment
            } else {
                // At least one non-digit: compare characters lexicographically
                if aChar != bChar {
                    return aChar < bChar
                }
                aNorm.formIndex(after: &aIdx)
                bNorm.formIndex(after: &bIdx)
            }
        }

        // All compared segments are equal — shorter string comes first
        return aIdx == aEnd && bIdx < bEnd
    }

    /// Delegate to the shared ``PathUtils/depth(_:)`` utility.
    public static func pathDepth(_ path: String) -> Int {
        PathUtils.depth(path)
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

    /// Extract a contiguous run of decimal digits starting at `idx`,
    /// parse it as an integer, and advance `idx` past the digits.
    /// Uses wrapping arithmetic (`&*`, `&+`) to handle pathologically long
    /// digit runs without trapping — sufficient for comparison purposes.
    private static func extractNumber(_ s: String, from idx: inout String.Index) -> UInt64 {
        var value: UInt64 = 0
        while idx < s.endIndex, s[idx].isNumber {
            guard let digit = s[idx].wholeNumberValue else { break }
            value = value &* 10 &+ UInt64(digit)
            s.formIndex(after: &idx)
        }
        return value
    }
}
