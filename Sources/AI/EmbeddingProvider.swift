/// # Embedding Provider Protocol
///
/// Protocol for generating vector embeddings from text. Embeddings power
/// semantic file search: natural language queries are embedded and compared
/// against pre-computed filename embeddings via cosine similarity.
///
/// Like ``AIModelProvider``, consumers accept `(any EmbeddingProvider)?`.
/// When `nil`, semantic search is silently disabled — callers fall back to
/// keyword-based search without code changes.
///
/// Conforms to `Sendable` for Swift 6 strict concurrency safety.
///
/// ## Protocol Methods
/// - ``embed(text:)`` -- generate an embedding for a single text string
/// - ``embedBatch(texts:)`` -- generate embeddings for multiple texts in parallel
///
/// ## Provider Registry
/// ``AIConfig`` manages the active embedding provider, similar to how it
/// manages the active ``AIModelProvider``. Providers register via a factory
/// function on ``AIConfig``.
///
/// ## Adding a New Provider
/// 1. Create a new file implementing ``EmbeddingProvider``
/// 2. Register in ``AIConfig`` -- no changes to existing provider code needed
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

// MARK: - EmbeddingProvider

/// Protocol for generating vector embeddings from text.
///
/// Embeddings power semantic file search. Natural language queries are
/// embedded using the same model as filename embeddings, then compared
/// via cosine similarity to find semantically related files.
///
/// The protocol supports both cloud-based providers (e.g., OpenAI-compatible
/// embeddings API) and on-device providers (e.g., Core ML models, Apple's
/// NLContextualEmbedding).
///
/// ## Graceful Degradation
///
/// All consumers accept `(any EmbeddingProvider)?`. When `nil`, semantic
/// search is disabled and callers fall back to keyword-based search.
/// No code changes needed in callers.
///
/// ## Concurrency
///
/// The protocol conforms to `Sendable`. The default `embedBatch` uses
/// `withThrowingTaskGroup` for concurrent processing with index-preserving
/// ordering. Providers may override for batch API calls (cloud) or SIMD
/// batching (on-device).
public protocol EmbeddingProvider: Sendable {
    /// Human-readable provider name (e.g., "nlcontextual", "qwen", "openai").
    var name: String { get }

    /// Output vector dimensionality.
    ///
    /// All vectors returned by `embed(text:)` and `embedBatch(texts:)`
    /// must have exactly this length. Callers use this to validate
    /// compatibility (e.g., stored vectors must match the active provider).
    var dimensions: Int { get }

    /// Generate an embedding for a single text string.
    ///
    /// - Parameter text: The text to embed. For filenames, use the NFC-normalized
    ///   display name. For queries, use the raw user input.
    /// - Returns: A Float32 vector of length `dimensions`, suitable for
    ///   cosine similarity comparison.
    func embed(text: String) async throws -> [Float]

    /// Generate embeddings for multiple texts in parallel.
    ///
    /// The default implementation uses `withThrowingTaskGroup` for concurrent
    /// processing, preserving input order. Providers may override for batch
    /// API calls (cloud providers) or SIMD batching (on-device models).
    ///
    /// - Parameter texts: The texts to embed. Order is preserved in the result.
    /// - Returns: Array of vectors, same count and order as input.
    func embedBatch(texts: [String]) async throws -> [[Float]]
}

// MARK: - Default Batch Implementation

extension EmbeddingProvider {
    /// Default batch implementation via concurrent single-item embedding.
    ///
    /// Uses `withThrowingTaskGroup` with index tracking to preserve input
    /// order in the result. Providers that support true batching (e.g.,
    /// cloud embeddings API) should override this for better throughput.
    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, try await self.embed(text: text)) }
            }
            var results: [(Int, [Float])] = []
            for try await pair in group { results.append(pair) }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
}
