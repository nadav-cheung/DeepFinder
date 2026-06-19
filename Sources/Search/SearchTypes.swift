// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex

// MARK: - Path Utilities

/// Shared path-depth computation used by both `SearchSorter` and `SearchFilter`.
///
/// Counts non-empty path components by splitting on "/" and filtering empty
/// segments. This handles trailing slashes and double slashes consistently
/// (e.g. "/a//b/" → 2, "" → 0).
public enum PathUtils {
    /// Returns the number of non-empty path components in `path`.
    public static func depth(_ path: String) -> Int {
        path.components(separatedBy: "/").filter { !$0.isEmpty }.count
    }
}

// MARK: - MatchType

/// Describes how a query matched a file name.
///
/// Lower `rawValue` equals higher priority, which drives result ordering.
/// For example, an exact match always sorts before a substring match.
public enum MatchType: Int, Codable, Comparable, Sendable {
    /// The query exactly matches the full filename (case-insensitive).
    case exact = 0
    /// The query matches the beginning of the filename.
    case prefix = 1
    /// The query matches via pinyin transliteration of Chinese characters.
    case pinyin = 2
    /// The query appears as a substring anywhere in the filename.
    case substring = 3

    public static func < (lhs: MatchType, rhs: MatchType) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - SearchQuery

/// A user search query, storing both the original input and a normalized form.
public struct SearchQuery: Sendable {
    /// Original user input, unmodified.
    public let rawQuery: String
    /// NFC-normalized + lowercased form (used for matching).
    public let normalizedQuery: String

    public init(_ query: String) {
        self.rawQuery = query
        self.normalizedQuery = query
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

// MARK: - SearchResult

/// A single search result from a provider.
///
/// Equality is determined by ``FileRecord/id`` for deduplication purposes --
/// two results pointing to the same file are considered equal regardless of
/// which provider produced them or what match type was detected.
public struct SearchResult: Codable, Sendable, Equatable {
    /// The file record that matched the query.
    public let record: FileRecord
    /// Identifier of the provider that produced this result (e.g. "file-index").
    public let providerID: String
    /// Relevance score assigned by the provider (higher is better).
    public let score: Double
    /// How the query matched the filename.
    public let matchType: MatchType
    /// Line-level content matches. Populated only for `content:` queries; `nil`
    /// for filename searches. Carried over IPC so the CLI can render line:column (REQ-1.4-03).
    public let contentMatches: [ContentMatchWire]?

    public init(
        record: FileRecord,
        providerID: String,
        score: Double,
        matchType: MatchType,
        contentMatches: [ContentMatchWire]? = nil
    ) {
        self.record = record
        self.providerID = providerID
        self.score = score
        self.matchType = matchType
        self.contentMatches = contentMatches
    }

    public static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.record.id == rhs.record.id
    }
}
