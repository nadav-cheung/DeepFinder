/// The compile-time privacy boundary between the search engine and AI providers.
///
/// Carries only file metadata (via FileMetadataSummary), never contents or thumbnails.
/// This is the sole data type allowed to cross into any AIModelProvider.call.
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

/// Context passed to AI model providers for completion requests.
///
/// **Privacy boundary**: This is the compile-time gateway between the search
/// engine and AI providers. It deliberately contains ONLY metadata -- never
/// file contents, thumbnails, or binary data. The type system enforces this:
/// `AIContext` can reference `FileMetadataSummary` but can never access
/// `FileRecord`'s raw fields (full paths, metadata blobs, etc.) except
/// through the anonymized summary produced by `FileMetadataSummary.from(_:)`.
///
/// This struct is the ONLY data type that crosses the AI module boundary.
/// If you need to pass additional context to an AI provider, add it here
/// (as metadata, never as file contents).
public struct AIContext: Sendable, Codable, Equatable {
    /// The user's original query string
    public let query: String
    /// Metadata summaries of search results (no file contents)
    public let resultMetadata: [FileMetadataSummary]
    /// Index statistics for context
    public let indexStats: IndexStats

    /// Summary statistics about the current index state
    public struct IndexStats: Sendable, Codable, Equatable {
        /// Total files in the index
        public let totalFiles: Int
        /// Number of results for the current query
        public let queryResults: Int
    }
}
