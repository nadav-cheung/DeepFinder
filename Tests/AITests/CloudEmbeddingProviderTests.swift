import Foundation
import Testing
@testable import DeepFinder

@Suite("CloudEmbeddingProvider")
struct CloudEmbeddingProviderTests {

    @Test("embed returns correct dimensions")
    func embedReturnsCorrectDimensions() async throws {
        let dim = 1024
        let embeddingValues = (0..<dim).map { String(format: "%.4f", Float($0) * 0.001) }.joined(separator: ",")
        let mockResponse = """
        {"data":[{"embedding":[\(embeddingValues)],"index":0}],"model":"text-embedding-v4"}
        """
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 200, data: Data(mockResponse.utf8)))
        let provider = CloudEmbeddingProvider(
            name: "qwen", endpoint: URL(string: "https://example.com/embeddings")!,
            apiKey: "sk-test", model: "text-embedding-v4", dimensions: dim, httpClient: http
        )
        let vec = try await provider.embed(text: "test.pdf")
        #expect(vec.count == dim)
    }

    @Test("embedBatch returns correct count")
    func embedBatchReturnsCorrectCount() async throws {
        let mockResponse = """
        {"data":[{"embedding":[0.1,0.2],"index":0},{"embedding":[0.3,0.4],"index":1}],"model":"test"}
        """
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 200, data: Data(mockResponse.utf8)))
        let provider = CloudEmbeddingProvider(
            name: "openai", endpoint: URL(string: "https://api.openai.com/v1/embeddings")!,
            apiKey: "sk-test", model: "text-embedding-3-small", dimensions: 512, httpClient: http
        )
        let results = try await provider.embedBatch(texts: ["a.txt", "b.txt"])
        #expect(results.count == 2)
    }

    @Test("HTTP 429 maps to rateLimited")
    func http429MapsToRateLimited() async throws {
        let http = MockHTTPClient(response: HTTPClientResponse(statusCode: 429, data: Data()))
        let provider = CloudEmbeddingProvider(
            name: "test", endpoint: URL(string: "https://example.com/")!,
            apiKey: "sk-test", model: "test", dimensions: 128, httpClient: http
        )
        do {
            _ = try await provider.embed(text: "test")
            Issue.record("Expected error")
        } catch let error as AIError {
            #expect(error == .rateLimited)
        }
    }

    @Test("provider metadata correct")
    func providerMetadata() {
        let provider = CloudEmbeddingProvider(
            name: "zhipu", endpoint: URL(string: "https://example.com/")!,
            apiKey: "sk-test", model: "embedding-3", dimensions: 1024
        )
        #expect(provider.name == "zhipu")
        #expect(provider.dimensions == 1024)
    }


}
