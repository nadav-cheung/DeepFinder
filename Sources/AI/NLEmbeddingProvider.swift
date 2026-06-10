/// On-device text embedding using NLContextualEmbedding (NaturalLanguage framework).
///
/// Routes CJK text to the Simplified Chinese model and Latin text to the Latin model,
/// then averages and L2-normalizes per-word vectors into a 512-dim embedding.
/// Zero network calls, zero dependencies.
@preconcurrency import Foundation
@preconcurrency import NaturalLanguage
import OSLog
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

private let logger = Logger(subsystem: Product.aiSubsystem, category: "nl-embedding")

/// On-device embedding provider using NLContextualEmbedding (NaturalLanguage framework).
///
/// Uses dual script-specific models:
/// - Simplified Chinese for CJK text (also covers Japanese/Korean Unicode ranges)
/// - Latin for English + European languages
///
/// For mixed text (Chinese + English), the text is tokenized per-word and each token
/// is routed to the appropriate script model. Token embeddings are averaged and
/// L2-normalized to produce the final 512-dim vector.
///
/// Model instances are loaded once and shared across all provider instances.
///
/// **Privacy**: All computation is on-device. Zero network calls. Zero dependencies.
/// **Availability**: macOS 14+. DeepFinder targets macOS 26+.
public struct NLEmbeddingProvider: EmbeddingProvider, Sendable {
    public let name = "nlcontextual"
    public let dimensions = 512

    /// Shared model instances — loaded once, reused across all provider instances.
    /// NLContextualEmbedding is @unchecked Sendable and safe for concurrent reads.
    private static let sharedLatin: NLContextualEmbedding? = {
        guard let emb = NLContextualEmbedding(script: .latin) else { return nil }
        do {
            try emb.load()
        } catch {
            logger.error("Failed to load latin model: \(error)")
            return nil
        }
        return emb
    }()

    private static let sharedCJK: NLContextualEmbedding? = {
        guard let emb = NLContextualEmbedding(script: .simplifiedChinese) else { return nil }
        do {
            try emb.load()
        } catch {
            logger.error("Failed to load simplifiedChinese model: \(error)")
            return nil
        }
        return emb
    }()

    private var latinEmbedding: NLContextualEmbedding? { Self.sharedLatin }
    private var cjkEmbedding: NLContextualEmbedding? { Self.sharedCJK }

    public init() {}

    public func embed(text: String) async throws -> [Float] {
        guard !text.isEmpty else {
            return Array(repeating: 0, count: dimensions)
        }
        return try computeEmbedding(text: text)
    }

    /// Sequential batch embedding — NLContextualEmbedding is not safe for
    /// concurrent calls even though it is @unchecked Sendable.
    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embed(text: text))
        }
        return results
    }

    // MARK: - Private

    private func computeEmbedding(text: String) throws -> [Float] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        var wordVectors: [[Float]] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            let isCJK = token.unicodeScalars.first.map { isCJKScalar($0) } ?? false
            let model = isCJK ? cjkEmbedding : latinEmbedding

            if let vec = pooledEmbedding(for: token, using: model) {
                wordVectors.append(vec)
            }
            return true
        }

        // Fallback: if no tokens, try the full string
        if wordVectors.isEmpty {
            if let vec = pooledEmbedding(for: text, using: latinEmbedding) {
                wordVectors.append(vec)
            } else if let vec = pooledEmbedding(for: text, using: cjkEmbedding) {
                wordVectors.append(vec)
            } else {
                return Array(repeating: 0, count: dimensions)
            }
        }

        // Average word vectors
        let count = Float(wordVectors.count)
        var averaged = Array(repeating: Float(0), count: dimensions)
        for vec in wordVectors {
            for i in 0..<min(dimensions, vec.count) {
                averaged[i] += vec[i] / count
            }
        }

        // L2 normalize
        let norm = sqrt(averaged.map { $0 * $0 }.reduce(0, +))
        guard norm > 0 else { return Array(repeating: 0, count: dimensions) }
        return averaged.map { $0 / norm }
    }

    /// Embeds a single word/phrase with the given model and mean-pools subword vectors.
    private func pooledEmbedding(
        for text: String,
        using embedding: NLContextualEmbedding?
    ) -> [Float]? {
        guard let embedding else { return nil }
        let result: NLContextualEmbeddingResult
        do {
            result = try embedding.embeddingResult(for: text, language: nil)
        } catch {
            logger.warning("Embedding failed for '\(text.prefix(20))': \(error)")
            return nil
        }

        var subwordVectors: [[Double]] = []
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            subwordVectors.append(vector)
            return true
        }

        guard !subwordVectors.isEmpty else { return nil }

        // Mean pool subword vectors into a single vector
        let count = Double(subwordVectors.count)
        let modelDim = Int(embedding.dimension)
        var pooled = Array(repeating: 0.0, count: modelDim)
        for vec in subwordVectors {
            for i in 0..<min(modelDim, vec.count) {
                pooled[i] += vec[i] / count
            }
        }
        return pooled.map { Float($0) }
    }
}

/// Check if a Unicode scalar is in the CJK range.
private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x4E00...0x9FFF,    // CJK Unified Ideographs
         0x3400...0x4DBF,    // CJK Extension A
         0x20000...0x2A6DF,  // CJK Extension B
         0xF900...0xFAFF,    // CJK Compatibility Ideographs
         0x3040...0x309F,    // Hiragana
         0x30A0...0x30FF,    // Katakana
         0xAC00...0xD7AF:    // Hangul
        return true
    default:
        return false
    }
}
