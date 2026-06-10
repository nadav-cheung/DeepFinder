/// Cloud-based embedding provider for OpenAI-compatible embedding APIs.
///
/// Sends filenames (not full paths) to remote endpoints and returns float vectors
/// for semantic similarity search. Supports any OpenAI-compatible /embeddings endpoint.
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

/// Cloud-based embedding provider for OpenAI-compatible embedding APIs.
///
/// Supports: Qwen text-embedding-v4, Zhipu Embedding-3, OpenAI text-embedding-3,
/// and any custom OpenAI-compatible embedding endpoint.
///
/// **Privacy**: Sends filenames (not full paths) to the cloud API.
/// The caller MUST sanitize input before passing to this provider.
public struct CloudEmbeddingProvider: EmbeddingProvider, Sendable {
    public let name: String
    public let dimensions: Int

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let httpClient: any HTTPClient

    public init(name: String, endpoint: URL, apiKey: String, model: String, dimensions: Int,
         httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.dimensions = dimensions
        self.httpClient = httpClient
    }

    public func embed(text: String) async throws -> [Float] {
        let results = try await embedBatch(texts: [text])
        guard let first = results.first else { throw AIError.invalidResponse }
        return first
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        let body: [String: Any] = ["model": model, "input": texts, "encoding_format": "float"]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.httpBody = bodyData

        let response = try await httpClient.perform(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 429 { throw AIError.rateLimited }
            throw AIError.networkError("HTTP \(response.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { throw AIError.invalidResponse }

        var results: [[Float]] = []
        results.reserveCapacity(data.count)
        for item in data {
            guard let embedding = item["embedding"] as? [Double] else {
                throw AIError.invalidResponse
            }
            results.append(embedding.map(Float.init))
        }
        return results
    }
}
