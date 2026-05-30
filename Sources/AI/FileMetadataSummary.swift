import Foundation

/// A privacy-safe summary of file metadata for AI consumption.
///
/// **Privacy boundary**: This is the ONLY data type that crosses into AI providers
/// from the search engine. It contains no file content, no thumbnails, no binary
/// data -- only metadata needed for search result summarization and query suggestion.
///
/// Paths are optionally anonymized via `anonymizePaths` (default `true`):
/// `/Users/nadav/file.txt` becomes `~/file.txt`. This prevents leaking the
/// macOS username to cloud AI providers. Controlled by `ai.pathAnonymization` config.
///
/// To construct: always use `FileMetadataSummary.from(_:tags:anonymizePaths:)`
/// which applies the privacy transformation. Do not construct directly with raw paths.
struct FileMetadataSummary: Sendable, Codable, Equatable {
    /// File name (e.g. "report.pdf")
    let name: String
    /// File path, optionally anonymized
    let path: String
    /// File size in bytes
    let size: Int64
    /// Last modification date
    let modifiedAt: Date
    /// File extension without dot (e.g. "pdf"), nil for directories
    let `extension`: String?
    /// Tags generated locally (e.g. Vision framework labels, user tags)
    let localTags: [String]

    /// Create a FileMetadataSummary from a FileRecord.
    ///
    /// - Parameters:
    ///   - record: The source FileRecord.
    ///   - tags: Locally-generated tags to include.
    ///   - anonymizePaths: If true, replace `/Users/<username>/` with `~/`.
    static func from(
        _ record: FileRecord,
        tags: [String] = [],
        anonymizePaths: Bool = true
    ) -> FileMetadataSummary {
        FileMetadataSummary(
            name: record.name,
            path: anonymizePaths ? Self.anonymize(record.path) : record.path,
            size: record.size,
            modifiedAt: record.modifiedAt,
            extension: record.extension,
            localTags: tags
        )
    }

    /// Replace `/Users/<username>/` prefix with `~/`.
    private static func anonymize(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        // Find the third "/" which marks the end of the username segment
        let afterPrefix = path.index(path.startIndex, offsetBy: 7) // after "/Users/"
        guard let slashRange = path[afterPrefix...].firstIndex(of: "/") else {
            // No trailing slash -- entire path is just /Users/username
            return "~"
        }
        let fullPathSlash = slashRange
        return "~" + path[fullPathSlash...]
    }
}
