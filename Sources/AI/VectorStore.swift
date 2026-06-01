import Foundation

/// Protocol for storing and searching dense vectors (embeddings).
///
/// Each vector is keyed by a `FileRecord.ID` (UInt64). The store supports
/// insert, search (cosine similarity, top-K), delete, and count operations.
///
/// Implementations:
/// - `FlatFileVectorStore` — memory-mapped file + BNNSVectorSearch (zero-dependency)
/// - Future: `SQLiteVectorStore` — sqlite-vector with quantization (vendored C)
///
/// Conforms to `Sendable` for Swift 6 strict concurrency safety.
/// Implementations should use actor isolation or locking for thread-safe storage.
protocol VectorStore: Sendable {
    /// Insert or update a vector for the given file ID.
    ///
    /// If a vector already exists for this ID, it is replaced.
    /// Vectors must match the dimensionality expected by the store (set at init).
    func insert(id: UInt64, vector: [Float]) async throws

    /// Search for the top-K most similar vectors by cosine similarity.
    ///
    /// Returns results sorted by descending similarity score (1.0 = identical, 0.0 = orthogonal).
    /// Fewer than `topK` results may be returned if the store has fewer entries.
    func search(query: [Float], topK: Int) async throws -> [(id: UInt64, score: Float)]

    /// Remove the vector for the given file ID. No-op if the ID is not present.
    func delete(id: UInt64) async throws

    /// Total number of vectors currently stored.
    func count() async -> Int
}
