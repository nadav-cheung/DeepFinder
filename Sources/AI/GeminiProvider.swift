import Foundation

/// Provider for Google's Gemini models via the Gemini API.
///
/// Gemini uses its own streaming format (not OpenAI-compatible):
/// - Endpoint: POST /v1beta/models/{model}:streamGenerateContent?alt=sse
/// - Auth: `x-goog-api-key` header
/// - Streaming: SSE `data:` lines with `candidates[].content.parts[].text`
///
/// Context (file metadata) is injected into the user message's `parts` array
/// since Gemini does not support a separate system message in generateContent.
///
/// REQ-3.0-Gemini.
struct GeminiProvider: AIModelProvider, Sendable {
    let name = "gemini"
    let displayName = "Google Gemini"
    let capabilities: Set<AICapability> = [.textToSearch, .resultSummary, .querySuggestion, .intentAnalysis]
    let supportsOnDevice = false
    let contextLimit = 1_000_000
    let hasEmbeddingAPI = true

    private let apiKey: String
    private let model: String
    private let httpClient: any HTTPClient
    let endpoint: URL

    private static let maxOutputTokens = Constants.AI.maxOutputTokens

    init(apiKey: String, model: String, httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
        let baseURL = ProviderRegistry.allProviders
            .first(where: { $0.name == "gemini" })?.defaultEndpoint
            ?? "https://generativelanguage.googleapis.com/v1beta"
        self.endpoint = URL(string: "\(baseURL)/models/\(model):streamGenerateContent?alt=sse")!
    }

    // MARK: - complete()

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try buildRequestBody(prompt: prompt, context: context)
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.httpBody = body

                    let response = try await httpClient.perform(request)
                    guard response.statusCode == 200 else {
                        if response.statusCode == 429 {
                            continuation.finish(throwing: AIError.rateLimited)
                        } else {
                            continuation.finish(throwing: AIError.networkError("HTTP \(response.statusCode)"))
                        }
                        return
                    }
                    parseSSEStream(response.data, continuation: continuation)
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.networkError(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - translateToSearchSyntax()

    func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
        let prompt = Self.searchTranslationPrompt.replacingOccurrences(
            of: "{{query}}", with: naturalLanguage
        )
        var result = ""
        for try await chunk in complete(prompt: prompt, context: nil) {
            result += chunk
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func buildRequestBody(prompt: String, context: AIContext?) throws -> Data {
        var parts: [[String: Any]] = [["text": prompt]]
        if let ctx = context, !ctx.resultMetadata.isEmpty {
            let fileNames = ctx.resultMetadata.prefix(30).map(\.name).joined(separator: ", ")
            parts.insert(
                ["text": "Search context (\(ctx.indexStats.queryResults) files): \(fileNames)"],
                at: 0
            )
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["maxOutputTokens": Self.maxOutputTokens],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Parse Gemini SSE stream format.
    ///
    /// Gemini SSE uses `data:` lines with JSON payloads containing
    /// `candidates[].content.parts[].text` for streaming content deltas.
    private func parseSSEStream(_ data: Data, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let lineStr = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineStr.hasPrefix("data:") else { continue }
            let jsonStr = String(lineStr.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let jsonData = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let candidates = obj["candidates"] as? [[String: Any]]
            else { continue }
            for candidate in candidates {
                guard let content = candidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]]
                else { continue }
                for part in parts {
                    if let textDelta = part["text"] as? String {
                        continuation.yield(textDelta)
                    }
                }
            }
        }
    }

    private static let searchTranslationPrompt = """
    Translate the following natural language query into \(Product.name) search syntax.
    Query: {{query}}
    Return ONLY the search syntax, no explanation.
    """
}
