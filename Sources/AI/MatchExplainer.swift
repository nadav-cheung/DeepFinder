/// Local, rule-based explanation of why a search result matched a query.
///
/// Purely heuristic (no AI required): inspects MatchType, file name, query text, and
/// active filters to produce a human-readable reason string. O(1) per result.
import Foundation

// MARK: - MatchExplanation

/// A human-readable explanation of why a search result matched.
struct MatchExplanation: Sendable, Equatable {
    /// Human-readable reason string (e.g. "Exact match: filename equals 'report.pdf'").
    let reason: String
    /// The match type as a string label: "exact", "prefix", "substring", "pinyin".
    let matchType: String
    /// The character offset where the query first appears in the file name, or nil if not applicable.
    let position: String?
}

// MARK: - MatchExplainer

/// Generates local, rule-based explanations for why a search result matched.
///
/// **No AI required**: Purely based on `MatchType`, file name, query text, and active
/// filters. Always available regardless of AI provider configuration. Runs in O(1)
/// per result -- no network calls, no caching needed.
///
/// This is intentionally a stateless enum with only static methods, not a struct
/// with a provider, because match explanation is a local heuristic that doesn't
/// benefit from AI.
enum MatchExplainer: Sendable {

    /// Produce a human-readable explanation for a search result.
    ///
    /// - Parameters:
    ///   - result: The search result to explain.
    ///   - query: The original (raw) user query string.
    ///   - filters: Any active metadata filters (empty array if none).
    /// - Returns: A `MatchExplanation` describing why this result matched.
    static func explain(result: SearchResult, query: String, filters: [SearchFilter]) -> MatchExplanation {
        let fileName = result.record.originalName
        let matchTypeLabel = label(for: result.matchType)
        let reason = buildReason(
            matchType: result.matchType,
            fileName: fileName,
            query: query,
            filters: filters
        )
        let position = findPosition(fileName: fileName, query: query)

        return MatchExplanation(
            reason: reason,
            matchType: matchTypeLabel,
            position: position
        )
    }

    // MARK: - Private

    private static func label(for matchType: MatchType) -> String {
        switch matchType {
        case .exact: return "exact"
        case .prefix: return "prefix"
        case .pinyin: return "pinyin"
        case .substring: return "substring"
        }
    }

    private static func buildReason(
        matchType: MatchType,
        fileName: String,
        query: String,
        filters: [SearchFilter]
    ) -> String {
        let matchDescription: String
        switch matchType {
        case .exact:
            matchDescription = "Exact match: filename equals '\(query)'"
        case .prefix:
            matchDescription = "Prefix match: filename starts with '\(query)'"
        case .substring:
            matchDescription = "Substring match: filename contains '\(query)'"
        case .pinyin:
            matchDescription = "Pinyin match: filename pinyin matches '\(query)'"
        }

        if filters.isEmpty {
            return matchDescription
        }

        let filterDescriptions = filters.map(describeFilter)
        return "\(matchDescription); also matches \(filterDescriptions.joined(separator: ", "))"
    }

    private static func describeFilter(_ filter: SearchFilter) -> String {
        switch filter {
        case .sizeMin(let bytes):
            return "size >= \(formatSize(bytes))"
        case .sizeMax(let bytes):
            return "size <= \(formatSize(bytes))"
        case .sizeRange(let range):
            return "size \(formatSize(range.lowerBound))...\(formatSize(range.upperBound))"
        case .dateModifiedAfter:
            return "date modified filter"
        case .dateModifiedBefore:
            return "date modified filter"
        case .dateModifiedRange:
            return "date modified filter"
        case .dateCreatedAfter:
            return "date created filter"
        case .dateCreatedBefore:
            return "date created filter"
        case .extensionFilter(let exts):
            let joined = exts.sorted().joined(separator: ", ")
            return "extension filter (\(joined))"
        case .isFile:
            return "file (not directory)"
        case .isDirectory:
            return "directory"
        case .maxDepth:
            return "depth filter"
        case .minDepth:
            return "depth filter"
        case .fileType(let group):
            return "file type (\(group.rawValue))"
        case .metadataMin(let field, let value):
            return "\(field) >= \(value)"
        case .metadataMax(let field, let value):
            return "\(field) <= \(value)"
        case .metadataRange(let field, let range):
            return "\(field) \(range.lowerBound)...\(range.upperBound)"
        case .metadataMatch(let field, let query):
            return "\(field) contains '\(query)'"
        }
    }

    private static func formatSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return "\(bytes / 1_073_741_824)gb"
        } else if bytes >= 1_048_576 {
            return "\(bytes / 1_048_576)mb"
        } else if bytes >= 1_024 {
            return "\(bytes / 1_024)kb"
        } else {
            return "\(bytes)b"
        }
    }

    /// Find the first occurrence of the lowercased query in the lowercased file name.
    /// Returns nil for pinyin matches (position is not meaningful for pinyin transliteration).
    private static func findPosition(fileName: String, query: String) -> String? {
        let lowered = fileName.lowercased()
        let queryLowered = query.lowercased()
        if let range = lowered.range(of: queryLowered) {
            let index = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            return String(index)
        }
        return nil
    }
}
