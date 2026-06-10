/// Claude (Anthropic) provider using the Messages API with SSE streaming.
///
/// Handles Anthropic-specific protocol differences: x-api-key header, anthropic-version
/// header, top-level system field, and content_block_delta event parsing.
import Foundation

/// Provider for Anthropic's Claude models via the Messages API.
///
/// Claude uses a different API format than OpenAI-compatible providers:
/// - Endpoint: POST /v1/messages
/// - Auth: `x-api-key` header + `anthropic-version` header
/// - Streaming: SSE with `event:` lines, `content_block_delta` events
/// - System prompt: top-level `system` field, not a message role
///
/// REQ-3.1-Anthropic.
struct AnthropicProvider: AIModelProvider, Sendable {
    let name = "anthropic"
    let displayName = "Claude (Anthropic)"
    let capabilities: Set<AICapability> = [.textToSearch, .resultSummary, .querySuggestion, .intentAnalysis]
    let supportsOnDevice = false
    let contextLimit = 200_000
    let hasEmbeddingAPI = false

    private let apiKey: String
    private let model: String
    private let httpClient: any HTTPClient
    private let endpoint: URL

    private static let maxOutputTokens = Constants.AI.maxOutputTokens

    init(apiKey: String, model: String, httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.model = model
        self.httpClient = httpClient
        let baseURL = ProviderRegistry.allProviders
            .first(where: { $0.name == "anthropic" })?.defaultEndpoint
            ?? "https://api.anthropic.com/v1"
        guard let url = URL(string: baseURL + "/messages") else {
            preconditionFailure("Invalid Anthropic endpoint URL: \(baseURL)/messages")
        }
        self.endpoint = url
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
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(Constants.AI.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
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
        var messages: [[String: String]] = [["role": "user", "content": prompt]]
        if let ctx = context, !ctx.resultMetadata.isEmpty {
            let fileNames = ctx.resultMetadata.prefix(30).map(\.name).joined(separator: ", ")
            messages.insert(
                ["role": "user", "content": "Search context (\(ctx.indexStats.queryResults) files): \(fileNames)"],
                at: 0
            )
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxOutputTokens,
            "messages": messages,
            "stream": true,
        ]
        // Anthropic uses top-level "system" field, not a message role
        if let ctx = context {
            body["system"] = "You are an AI assistant helping with file search. " +
                "Query: \(ctx.query). Results: \(ctx.indexStats.queryResults) files."
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Parse Anthropic SSE stream format.
    ///
    /// Anthropic SSE uses `event:` lines to identify message types, followed by
    /// `data:` lines with JSON payloads. We extract text from `content_block_delta`
    /// events only; all other event types (message_start, content_block_start,
    /// content_block_stop, message_stop, ping) are silently skipped.
    private func parseSSEStream(_ data: Data, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let lineStr = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineStr.hasPrefix("data:") else { continue }
            let jsonStr = String(lineStr.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let jsonData = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            if type == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               let textDelta = delta["text"] as? String {
                continuation.yield(textDelta)
            }
        }
    }

    // MARK: - Prompt Engineering

    /// System prompt for the search syntax translation feature.
    ///
    /// Uses `{{query}}` placeholder for the natural language input.
    /// Instructs Claude to output ONLY the search syntax with no explanation.
    private static let searchTranslationPrompt = """
        You are a search syntax translator for \(Product.name), a macOS file search app.

        Translate the user's natural language query into \(Product.name) search syntax.

        \(Product.name) search syntax supports:
        - Plain text for substring matching (e.g. "report")
        - ext:pdf or ext:pdf;doc;xls for file extension filtering
        - size:>100mb or size:<1kb for size filtering
        - dm:today, dm:yesterday, dm:lastweek, dm:thismonth, dm:thisyear for date modified
        - path:Documents for path filtering
        - AND, OR for boolean operators
        - | for OR between terms
        - ! for NOT
        - case:exact for case-sensitive matching

        Query: {{query}}

        Rules:
        - Output ONLY the search syntax, nothing else.
        - No explanations, no markdown formatting.
        - If the query is ambiguous, make reasonable assumptions.
        - Support both Chinese and English natural language input.
        """
}
