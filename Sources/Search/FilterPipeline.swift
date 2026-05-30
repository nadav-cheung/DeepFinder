import Foundation

// MARK: - FilterPipeline

/// A pipeline of `SearchFilter` predicates applied to search results.
///
/// All filters must match (AND semantics). Results that fail any filter are
/// removed. Order of surviving results is preserved.
struct FilterPipeline: Sendable {
    /// The filters composing this pipeline. Public for test introspection.
    let filters: [SearchFilter]

    init(filters: [SearchFilter]) {
        self.filters = filters
    }

    /// Apply all filters to the results array.
    /// Returns only results whose record passes every filter.
    /// Preserves the original order of matching results.
    func apply(to results: [SearchResult]) -> [SearchResult] {
        guard !filters.isEmpty else { return results }
        return results.filter { result in
            filters.allSatisfy { filter in
                filter.matches(result.record)
            }
        }
    }

    /// Parse modifier pairs into a `FilterPipeline`.
    ///
    /// Supported modifiers:
    /// - `"size:">1mb"` → sizeMin
    /// - `"size:<1mb"` → sizeMax
    /// - `"size:1mb..10mb"` → sizeRange
    /// - `"ext:pdf"` → extensionFilter
    /// - `"ext:pdf;doc"` → extensionFilter (multiple)
    /// - `"file:"` → isFile
    /// - `"folder:"` → isDirectory
    /// - `"dm:today"` → dateModifiedAfter
    /// - `"depth:3"` → maxDepth
    static func parse(from modifiers: [(key: String, value: String)]) -> FilterPipeline {
        var parsedFilters: [SearchFilter] = []

        for (key, value) in modifiers {
            let lowerKey = key.lowercased()
            switch lowerKey {
            case "size":
                if let filter = SearchFilter.parseSizeFilter(value) {
                    parsedFilters.append(filter)
                }
            case "ext":
                if let filter = parseExtensionFilter(value) {
                    parsedFilters.append(filter)
                }
            case "file":
                parsedFilters.append(.isFile)
            case "folder":
                parsedFilters.append(.isDirectory)
            case "dm":
                if let filter = SearchFilter.parseDateFilter(value, referenceDate: Date()) {
                    parsedFilters.append(filter)
                }
            case "depth":
                if let filter = parseDepthFilter(value) {
                    parsedFilters.append(filter)
                }
            case "width", "height", "duration", "pages", "pageCount", "fps", "bitRate":
                let normalizedKey = lowerKey == "pages" ? "pageCount" : lowerKey
                if let filter = parseMetadataNumericFilter(key: normalizedKey, value: value) {
                    parsedFilters.append(filter)
                }
            case "artist", "album", "title", "genre", "codec":
                parsedFilters.append(.metadataMatch(lowerKey, value))
            default:
                break
            }
        }

        return FilterPipeline(filters: parsedFilters)
    }
}

// MARK: - Parsing Helpers (pipeline-specific)

extension FilterPipeline {

    /// Parse extension filter value.
    /// Examples: "pdf", "pdf;doc;xlsx"
    private static func parseExtensionFilter(_ value: String) -> SearchFilter? {
        if value.isEmpty {
            return .extensionFilter([])
        }
        let exts = Set(value.split(separator: ";").map { $0.lowercased() })
        return .extensionFilter(exts)
    }

    /// Parse depth filter value.
    /// Examples: "3", "<=5"
    private static func parseDepthFilter(_ value: String) -> SearchFilter? {
        let trimmed = value.lowercased()
        let numStr: String

        if trimmed.hasPrefix("<=") {
            numStr = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix(">=") {
            numStr = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("<") {
            numStr = String(trimmed.dropFirst(1))
        } else if trimmed.hasPrefix(">") {
            numStr = String(trimmed.dropFirst(1))
        } else {
            numStr = trimmed
        }

        guard let depth = Int(numStr) else { return nil }
        return .maxDepth(depth)
    }

    /// Parse metadata numeric filter value.
    /// Examples: ">2560", "<300", ">=100", "10..50", "1920"
    private static func parseMetadataNumericFilter(key: String, value: String) -> SearchFilter? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix(">=") {
            guard let n = Int(trimmed.dropFirst(2)) else { return nil }
            return .metadataMin(key, n)
        }
        if trimmed.hasPrefix(">") {
            guard let n = Int(trimmed.dropFirst()) else { return nil }
            return .metadataMin(key, n + 1)
        }
        if trimmed.hasPrefix("<=") {
            guard let n = Int(trimmed.dropFirst(2)) else { return nil }
            return .metadataMax(key, n)
        }
        if trimmed.hasPrefix("<") {
            guard let n = Int(trimmed.dropFirst()) else { return nil }
            return .metadataMax(key, n - 1)
        }
        // Range: "10..50"
        if let sep = trimmed.range(of: "..") {
            let lo = Int(trimmed[..<sep.lowerBound])
            let hi = Int(trimmed[sep.upperBound...])
            if let lo, let hi { return .metadataRange(key, lo...hi) }
        }
        // Exact match
        guard let n = Int(trimmed) else { return nil }
        return .metadataRange(key, n...n)
    }
}
