import Foundation

/// Context passed to AI model providers for completion requests.
///
/// Deliberately contains ONLY metadata -- never file contents.
/// This is the compile-time privacy boundary: AIContext can reference
/// FileMetadataSummary but can never access FileRecord's raw fields
/// (such as full paths, metadata blobs, etc.) except through the
/// anonymized summary.
struct AIContext: Sendable, Codable, Equatable {
    /// The user's original query string
    let query: String
    /// Metadata summaries of search results (no file contents)
    let resultMetadata: [FileMetadataSummary]
    /// Index statistics for context
    let indexStats: IndexStats

    /// Summary statistics about the current index state
    struct IndexStats: Sendable, Codable, Equatable {
        /// Total files in the index
        let totalFiles: Int
        /// Number of results for the current query
        let queryResults: Int
    }
}
