import Foundation

// MARK: - MatchType

/// Describes how a query matched a file name.
/// Lower rawValue = higher priority (used for result ordering).
enum MatchType: Int, Codable, Comparable, Sendable {
    case exact = 0
    case prefix = 1
    case pinyin = 2
    case substring = 3

    static func < (lhs: MatchType, rhs: MatchType) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - SearchQuery

/// A user search query, storing both the original input and a normalized form.
struct SearchQuery: Sendable {
    /// Original user input, unmodified.
    let rawQuery: String
    /// NFC-normalized + lowercased form (used for matching).
    let normalizedQuery: String

    init(_ query: String) {
        self.rawQuery = query
        self.normalizedQuery = query
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

// MARK: - SearchResult

/// A single search result from a provider.
/// Equality is determined by record.id for deduplication purposes.
struct SearchResult: Codable, Sendable, Equatable {
    let record: FileRecord
    let providerID: String
    let score: Double
    let matchType: MatchType

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.record.id == rhs.record.id
    }
}
