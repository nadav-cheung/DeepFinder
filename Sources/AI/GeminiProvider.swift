/// Google Gemini provider using the generateContent API with SSE streaming.
///
/// Handles Gemini-specific protocol: x-goog-api-key auth, candidates/parts/text
/// JSON structure, and context injection into the user message parts array.
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

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
public struct GeminiProvider: AIModelProvider, Sendable {
    public let name = "gemini"
    public let displayName = "Google Gemini"
    public let capabilities: Set<AICapability> = [.textToSearch, .resultSummary, .querySuggestion, .intentAnalysis]
    public let supportsOnDevice = false
    public let contextLimit = 1_000_000
    public let hasEmbeddingAPI = true

    private let apiKey: String
    private let model: String
    private let httpClient: any HTTPClient
    public let endpoint: URL

    private static let maxOutputTokens = Constants.AI.maxOutputTokens

    public init(apiKey: String, model: String, httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
        let baseURL = ProviderRegistry.allProviders
            .first(where: { $0.name == "gemini" })?.defaultEndpoint
            ?? "https://generativelanguage.googleapis.com/v1beta"
        guard let url = URL(string: "\(baseURL)/models/\(model):streamGenerateContent?alt=sse") else {
            preconditionFailure("Invalid Gemini endpoint URL for model: \(model)")
        }
        self.endpoint = url
    }

    // MARK: - complete()

    public func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try buildRequestBody(prompt: prompt, context: context)
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.httpBody = body

                    let response = try await performWithRetry(request: request)
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

    public func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
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

    /// Perform an HTTP request with exponential backoff retry.
    ///
    /// Retry strategy (max 3 attempts):
    /// - HTTP 200-399: return immediately
    /// - HTTP 429: sleep for 2^attempt seconds (with +/-25% jitter), then retry
    /// - Transport error: sleep for 2^attempt seconds, then retry
    /// - Other HTTP errors: throw immediately (no retry)
    /// - After 3 failed attempts for 429/transport: throw `AIError.rateLimited`
    ///   or `AIError.networkError` respectively
    private func performWithRetry(request: URLRequest) async throws -> HTTPClientResponse {
        var lastError: Error = AIError.networkError("Unknown")
        let maxAttempts = Constants.AI.maxRetryAttempts
        for attempt in 0..<maxAttempts {
            do {
                let response = try await httpClient.perform(request)
                if response.statusCode == 429 {
                    lastError = AIError.rateLimited
                    if attempt < maxAttempts - 1 {
                        let delay = Double(1 << attempt) * (0.75 + Double.random(in: 0...0.5))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    throw AIError.rateLimited
                }
                if response.statusCode >= 400 {
                    throw AIError.networkError("HTTP \(response.statusCode)")
                }
                return response
            } catch let error as AIError {
                if error == .rateLimited {
                    lastError = error
                    if attempt < maxAttempts - 1 {
                        continue
                    }
                }
                throw error
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    let delay = Double(1 << attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

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
