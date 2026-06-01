import Foundation

// MARK: - FileTypeGroup

/// Predefined file-type groups with their associated extensions.
///
/// Used by the ``SearchFilter/fileType(_:)`` filter case and the `type:` query modifier.
/// Each group maps to a curated set of common file extensions.
enum FileTypeGroup: String, Sendable {
    /// Audio files: mp3, wav, aac, flac, ogg, wma, m4a.
    case audio
    /// Video files: mp4, mov, avi, mkv, wmv, flv, webm.
    case video
    /// Image files: jpg, jpeg, png, gif, bmp, svg, webp, tiff, ico.
    case picture
    /// Document files: pdf, doc, docx, xls, xlsx, ppt, pptx, txt, rtf, odt.
    case document

    /// All extensions in this group, lowercased, without leading dots.
    var extensions: Set<String> {
        switch self {
        case .audio:
            return ["mp3", "wav", "aac", "flac", "ogg", "wma", "m4a"]
        case .video:
            return ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm"]
        case .picture:
            return ["jpg", "jpeg", "png", "gif", "bmp", "svg", "webp", "tiff", "ico"]
        case .document:
            return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt"]
        }
    }
}

// MARK: - SearchFilter

/// A single filter predicate that evaluates a `FileRecord`.
///
/// Each case wraps the minimal data needed to test whether a record matches.
/// Filters are applied after text search in the `FilterPipeline` (AND semantics).
enum SearchFilter: Sendable, Equatable {
    /// size >= N bytes
    case sizeMin(Int64)
    /// size <= N bytes
    case sizeMax(Int64)
    /// size in closed range
    case sizeRange(ClosedRange<Int64>)
    /// modifiedAt > date
    case dateModifiedAfter(Date)
    /// modifiedAt < date
    case dateModifiedBefore(Date)
    /// modifiedAt in half-open range
    case dateModifiedRange(Range<Date>)
    /// createdAt > date
    case dateCreatedAfter(Date)
    /// createdAt < date
    case dateCreatedBefore(Date)
    /// extension (lowercased) in set
    case extensionFilter(Set<String>)
    /// file (not directory)
    case isFile
    /// directory (not file)
    case isDirectory
    /// path component count <= N
    case maxDepth(Int)
    /// path component count >= N
    case minDepth(Int)
    /// extension matches a predefined type group
    case fileType(FileTypeGroup)
    /// Metadata numeric field >= N
    case metadataMin(String, Int)
    /// Metadata numeric field <= N
    case metadataMax(String, Int)
    /// Metadata numeric field in range
    case metadataRange(String, ClosedRange<Int>)
    /// Metadata string field contains substring
    case metadataMatch(String, String)

    // MARK: - Matching

    /// Returns `true` if the record satisfies this filter.
    func matches(_ record: FileRecord) -> Bool {
        switch self {
        case .sizeMin(let min):
            return record.size >= min
        case .sizeMax(let max):
            return record.size <= max
        case .sizeRange(let range):
            return range.contains(record.size)
        case .dateModifiedAfter(let date):
            return record.modifiedAt > date
        case .dateModifiedBefore(let date):
            return record.modifiedAt < date
        case .dateModifiedRange(let range):
            return range.contains(record.modifiedAt)
        case .dateCreatedAfter(let date):
            return record.createdAt > date
        case .dateCreatedBefore(let date):
            return record.createdAt < date
        case .extensionFilter(let exts):
            guard let ext = record.extension else { return false }
            return exts.contains(ext.lowercased())
        case .isFile:
            return !record.isDirectory
        case .isDirectory:
            return record.isDirectory
        case .maxDepth(let depth):
            return Self.pathDepth(record.path) <= depth
        case .minDepth(let depth):
            return Self.pathDepth(record.path) >= depth
        case .fileType(let group):
            guard let ext = record.extension else { return false }
            return group.extensions.contains(ext.lowercased())
        case .metadataMin(let field, let threshold):
            guard let meta = record.metadata,
                  let value = meta.fields[field]?.doubleValue else { return false }
            return Int(value) >= threshold
        case .metadataMax(let field, let threshold):
            guard let meta = record.metadata,
                  let value = meta.fields[field]?.doubleValue else { return false }
            return Int(value) <= threshold
        case .metadataRange(let field, let range):
            guard let meta = record.metadata,
                  let value = meta.fields[field]?.doubleValue else { return false }
            return range.contains(Int(value))
        case .metadataMatch(let field, let query):
            guard let meta = record.metadata,
                  let value = meta.fields[field]?.stringValue else { return false }
            return value.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Size Parsing

    /// Parses a human-readable size filter string.
    ///
    /// Supported formats:
    /// - `">1mb"`  -> `.sizeMin(1_048_576)`
    /// - `"<10kb"` -> `.sizeMax(10_240)`
    /// - `"100kb..10mb"` -> `.sizeRange(102_400...10_485_760)`
    /// - `"5gb"`   -> `.sizeMin(5_368_709_120)` (bare value treated as min)
    ///
    /// Units: b, kb, mb, gb (case insensitive).
    static func parseSizeFilter(_ input: String) -> SearchFilter? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Range: "100kb..10mb"
        if let rangeResult = parseSizeRange(trimmed) {
            return rangeResult
        }

        // Comparison prefix: ">1mb", "<10kb", ">=1mb", "<=10kb"
        if trimmed.hasPrefix(">=") {
            guard let bytes = parseByteCount(String(trimmed.dropFirst(2))) else { return nil }
            return .sizeMin(bytes)
        }
        if trimmed.hasPrefix(">") {
            guard let bytes = parseByteCount(String(trimmed.dropFirst())) else { return nil }
            return .sizeMin(bytes)
        }
        if trimmed.hasPrefix("<=") {
            guard let bytes = parseByteCount(String(trimmed.dropFirst(2))) else { return nil }
            return .sizeMax(bytes)
        }
        if trimmed.hasPrefix("<") {
            guard let bytes = parseByteCount(String(trimmed.dropFirst())) else { return nil }
            return .sizeMax(bytes)
        }

        // Bare value: "5gb" -> exact match treated as sizeMin
        guard let bytes = parseByteCount(trimmed) else { return nil }
        return .sizeMin(bytes)
    }

    // MARK: - Date Parsing

    /// Parses a human-readable date filter string relative to a reference date.
    ///
    /// Supported formats:
    /// - `"today"`, `"yesterday"`, `"thisweek"`, `"thismonth"`, `"thisyear"`
    /// - `"2026-01-01..2026-03-31"` -> date range (exclusive upper bound = start of next day)
    static func parseDateFilter(_ input: String, referenceDate: Date) -> SearchFilter? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = Calendar(identifier: .gregorian)

        switch trimmed {
        case "today":
            let start = cal.startOfDay(for: referenceDate)
            return .dateModifiedAfter(start)

        case "yesterday":
            let todayStart = cal.startOfDay(for: referenceDate)
            guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) else {
                return nil
            }
            return .dateModifiedRange(yesterdayStart..<todayStart)

        case "thisweek":
            let weekday = cal.component(.weekday, from: referenceDate)
            // Sunday=1, Monday=2, ... Saturday=7
            let daysSinceMonday = (weekday + 5) % 7
            let monday = cal.date(
                byAdding: .day,
                value: -daysSinceMonday,
                to: cal.startOfDay(for: referenceDate)
            )!
            return .dateModifiedAfter(monday)

        case "thismonth":
            let components = cal.dateComponents([.year, .month], from: referenceDate)
            guard let monthStart = cal.date(from: components) else { return nil }
            return .dateModifiedAfter(monthStart)

        case "thisyear":
            let components = cal.dateComponents([.year], from: referenceDate)
            guard let yearStart = cal.date(from: components) else { return nil }
            return .dateModifiedAfter(yearStart)

        default:
            return parseExplicitDateRange(trimmed, calendar: cal)
        }
    }

    // MARK: - Private Helpers

    /// Count path components by splitting on "/" and filtering empty segments.
    private static func pathDepth(_ path: String) -> Int {
        path.components(separatedBy: "/").filter { !$0.isEmpty }.count
    }

    private static func parseByteCount(_ input: String) -> Int64? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        let suffixes: [(String, Int64)] = [
            ("gb", 1_073_741_824),
            ("mb", 1_048_576),
            ("kb", 1_024),
            ("b", 1),
        ]

        for (suffix, multiplier) in suffixes {
            if s.hasSuffix(suffix) {
                let numStr = String(s.dropLast(suffix.count))
                guard let num = Int64(numStr) else { return nil }
                return num * multiplier
            }
        }

        // Bare number = bytes
        return Int64(s)
    }

    private static func parseSizeRange(_ input: String) -> SearchFilter? {
        guard let sep = input.range(of: "..") else { return nil }
        let left = String(input[..<sep.lowerBound])
        let right = String(input[sep.upperBound...])
        guard let lo = parseByteCount(left), let hi = parseByteCount(right) else { return nil }
        return .sizeRange(lo...hi)
    }

    private static func parseExplicitDateRange(_ input: String, calendar cal: Calendar) -> SearchFilter? {
        guard let sep = input.range(of: "..") else { return nil }
        let leftStr = String(input[..<sep.lowerBound])
        let rightStr = String(input[sep.upperBound...])
        guard let lower = parseDateOnly(leftStr, calendar: cal),
              let upper = parseDateOnly(rightStr, calendar: cal) else { return nil }
        // Upper bound is exclusive: advance to start of next day
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: upper) else { return nil }
        return .dateModifiedRange(lower..<nextDay)
    }

    private static func parseDateOnly(_ input: String, calendar cal: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: input.trimmingCharacters(in: .whitespaces))
    }
}
