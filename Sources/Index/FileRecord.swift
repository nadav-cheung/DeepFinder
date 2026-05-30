import Foundation

/// An immutable record representing a single file or directory in the index.
///
/// All filenames are NFC-normalized on ingestion via `precomposedStringWithCanonicalMapping`.
/// The ``name`` field holds the normalized form used for matching; ``originalName``
/// preserves the raw filesystem name for display.
///
/// Conforms to `Codable` for SQLite persistence and `Sendable` for safe cross-actor transfer.
struct FileRecord: Codable, Sendable {
    /// Unique numeric identifier within this index instance.
    let id: UInt32

    /// NFC-normalized filename used for search matching (lowercased during indexing).
    let name: String

    /// Original filename as it appears on disk, preserved for display.
    let originalName: String

    /// Absolute path to this file or directory (e.g. "/Users/nadav/Documents/report.pdf").
    let path: String

    /// Absolute path to the parent directory.
    let parentPath: String

    /// `true` for directories, `false` for regular files.
    let isDirectory: Bool

    /// File size in bytes. Zero for directories.
    let size: Int64

    /// File creation date from filesystem metadata.
    let createdAt: Date

    /// Last modification date from filesystem metadata.
    let modifiedAt: Date

    /// File extension without the leading dot (e.g. "pdf", "swift"). `nil` for directories.
    let `extension`: String?

    /// Optional media metadata extracted from the file (image dimensions, audio tags, etc.).
    let metadata: ExtractedMetadata?

    init(
        id: UInt32,
        name: String,
        originalName: String,
        path: String,
        parentPath: String,
        isDirectory: Bool,
        size: Int64,
        createdAt: Date,
        modifiedAt: Date,
        extension: String?,
        metadata: ExtractedMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.originalName = originalName
        self.path = path
        self.parentPath = parentPath
        self.isDirectory = isDirectory
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.extension = `extension`
        self.metadata = metadata
    }
}
