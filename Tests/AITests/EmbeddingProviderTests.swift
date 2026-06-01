import Foundation
import Testing
@testable import DeepFinder

@Suite("EmbeddingProvider")
struct EmbeddingProviderTests {

    @Test("embed returns correct dimensions")
    func embedReturnsCorrectDimensions() async throws {
        let provider = MockEmbeddingProvider(dimensions: 512)
        let result = try await provider.embed(text: "hello")
        #expect(result.count == 512)
    }

    @Test("embedBatch returns correct count and dimensions")
    func embedBatchReturnsCorrectCount() async throws {
        let provider = MockEmbeddingProvider(dimensions: 256)
        let results = try await provider.embedBatch(texts: ["a", "b", "c"])
        #expect(results.count == 3)
        for vector in results {
            #expect(vector.count == 256)
        }
    }

    @Test("provider name and dimensions properties")
    func providerNameAndDimensions() async throws {
        let provider = MockEmbeddingProvider(dimensions: 768)
        #expect(provider.name == "mock")
        #expect(provider.dimensions == 768)
    }

    @Test("nil provider pattern allows graceful degradation")
    func nilProviderPattern() {
        let provider: (any EmbeddingProvider)? = nil
        #expect(provider == nil)
    }

    @Test("MockEmbeddingProvider is Sendable")
    func mockIsSendable() {
        let provider = MockEmbeddingProvider(dimensions: 128)
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(provider)
    }
}

// MARK: - Mock Implementation

/// A mock EmbeddingProvider for testing.
struct MockEmbeddingProvider: EmbeddingProvider {
    let name: String = "mock"
    let dimensions: Int

    func embed(text: String) async throws -> [Float] {
        Array(repeating: Float.random(in: -1...1), count: dimensions)
    }

    func embedBatch(texts: [String]) async throws -> [[Float]] {
        try await withThrowingTaskGroup(of: [Float].self) { group in
            for text in texts {
                group.addTask { try await self.embed(text: text) }
            }
            var results: [[Float]] = []
            for try await vec in group { results.append(vec) }
            return results
        }
    }
}
