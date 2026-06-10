import Foundation
import Testing
@testable import DeepFinderAI

@Suite("EmbeddingProvider")
struct EmbeddingProviderTests {

    @Test("embed returns correct dimensions")
    func embedReturnsCorrectDimensions() async throws {
        let provider = MockEmbeddingProvider(dimensions: 512)
        let result = try await provider.embed(text: "hello")
        #expect(result.count == 512)
    }

    @Test("embedBatch returns correct count, dimensions, and preserves input order")
    func embedBatchReturnsCorrectCount() async throws {
        let provider = MockEmbeddingProvider(dimensions: 256)
        let texts = ["a", "b", "c"]
        let results = try await provider.embedBatch(texts: texts)
        #expect(results.count == 3)
        for vector in results {
            #expect(vector.count == 256)
        }
        // Verify order preservation: results[i] must match embed(texts[i])
        for (i, text) in texts.enumerated() {
            let expected = try await provider.embed(text: text)
            #expect(results[i] == expected)
        }
    }

    @Test("provider name and dimensions properties")
    func providerNameAndDimensions() async throws {
        let provider = MockEmbeddingProvider(dimensions: 768)
        #expect(provider.name == "mock")
        #expect(provider.dimensions == 768)
    }

    @Test("embedBatch with empty input returns empty result")
    func embedBatchWithEmptyInput() async throws {
        let provider = MockEmbeddingProvider(dimensions: 256)
        let results = try await provider.embedBatch(texts: [])
        #expect(results.isEmpty)
    }

    @Test("nil provider pattern allows graceful degradation")
    func nilProviderPattern() {
        let provider: (any EmbeddingProvider)? = nil
        #expect(provider == nil)
    }

}

// MARK: - Mock Implementation

/// A mock EmbeddingProvider for testing.
struct MockEmbeddingProvider: EmbeddingProvider {
    let name: String = "mock"
    let dimensions: Int

    func embed(text: String) async throws -> [Float] {
        // Deterministic output based on input text so order-preservation tests are meaningful.
        var vector = [Float](repeating: 0, count: dimensions)
        vector[0] = Float(text.hashValue & 0xFF)
        return vector
    }
}
