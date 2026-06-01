import Foundation

// MARK: - OpenAI-Compatible Protocol Layer
//
// DeepSeek and Qwen both expose chat completions APIs that follow the OpenAI format:
//   POST /chat/completions with { model, messages, stream: true }
//   SSE response: "data: {"choices":[{"delta":{"content":"..."}}]}"
//   Termination: "data: [DONE]"
//
// Rather than duplicating HTTP + SSE + JSON parsing for each provider, we implement
// the shared logic once in OpenAICompatibleProvider. Concrete providers (DeepSeek, Qwen)
// are typealiases that provide factory methods with the correct endpoint URL and model name.
//
// To add a new OpenAI-compatible provider:
//   1. Add a typealias at the bottom of this file
//   2. Add a static factory method with the provider's endpoint and default model
//   3. No other changes needed -- SSE parsing, error handling, and streaming are shared.

/// A generic AI model provider for OpenAI-compatible chat completions APIs.
///
/// Shared implementation for providers that use the same SSE streaming format
/// (DeepSeek, Qwen, and any future OpenAI-compatible endpoint).
///
/// **Streaming**: `complete()` returns an `AsyncThrowingStream` that yields content
/// deltas as they arrive from the SSE stream. Errors (rate limits, network failures)
/// are propagated as `AIError` through the stream's terminal event. The continuation
/// is always finished (with value or error) -- no leaked continuations.
///
/// **Error handling**:
/// - HTTP 429 -> `AIError.rateLimited`
/// - HTTP 4xx/5xx -> `AIError.networkError("HTTP \(statusCode)")`
/// - Transport errors -> wrapped in `AIError.networkError`
/// - `AIError` instances propagate unchanged (e.g., from a failing HTTPClient mock)
///
/// **Privacy**: Only ``AIContext`` data (metadata, never file contents) is serialized
/// into requests. The `encodeContext` helper strips file paths to names-only when
/// constructing the system message. See module-level docs for the full privacy model.
///
/// REQ-3.0-03 (DeepSeek) and REQ-3.0-04 (Qwen) both use this base.
struct OpenAICompatibleProvider: AIModelProvider, Sendable {
    let name: String
    let capabilities: Set<AICapability>
    let apiKey: String
    let model: String
    let httpClient: any HTTPClient
    let timeout: TimeInterval
    private let endpoint: URL

    init(
        name: String,
        endpoint: URL,
        apiKey: String,
        model: String,
        capabilities: Set<AICapability> = [.textToSearch, .resultSummary, .querySuggestion, .intentAnalysis],
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        timeout: TimeInterval = 30
    ) {
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.capabilities = capabilities
        self.httpClient = httpClient
        self.timeout = timeout
    }

    // MARK: - complete()

    /// Stream a chat completion using the OpenAI-compatible SSE protocol.
    ///
    /// The continuation is guaranteed to finish (with `.finish()` or `.finish(throwing:)`)
    /// on every code path -- no leaked continuations. Error paths:
    /// - HTTP 429 (after 3 retries) -> `AIError.rateLimited`
    /// - HTTP 4xx/5xx -> `AIError.networkError`
    /// - Transport error (after 3 retries) -> wrapped in `AIError.networkError`
    /// - `AIError` from HTTPClient -> propagated unchanged
    ///
    /// The HTTP call is wrapped in ``performWithRetry(request:)`` which retries
    /// on 429 and transport errors with exponential backoff + jitter (max 3 attempts).
    ///
    /// If the consuming `Task` is cancelled, `AsyncThrowingStream` handles
    /// cancellation by terminating iteration -- the continuation may yield a few
    /// more chunks before the task's cooperative cancellation takes effect.
    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try buildRequest(prompt: prompt, context: context)
                    let response = try await performWithRetry(request: request)

                    for await line in SSELineSequence(data: response.data) {
                        if line == "data: [DONE]" { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        if let content = Self.parseContentDelta(from: jsonStr), !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AIError.networkError(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - translateToSearchSyntax()

    /// Translate natural language into search syntax using a non-streaming call.
    ///
    /// Unlike `complete()`, this collects the full response before returning.
    /// Throws on HTTP errors and transport failures -- callers should `catch`
    /// and fall back to returning the input unchanged (see `NLSearchTranslator`).
    func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
        let request = try buildRequest(
            systemPrompt: Self.searchTranslationSystemPrompt,
            userMessage: naturalLanguage
        )
        let response = try await httpClient.perform(request)

        if response.statusCode == 429 { throw AIError.rateLimited }
        if response.statusCode >= 400 { throw AIError.networkError("HTTP \(response.statusCode)") }

        var fullText = ""
        for await line in SSELineSequence(data: response.data) {
            if line == "data: [DONE]" { break }
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if let content = Self.parseContentDelta(from: jsonStr) {
                fullText += content
            }
        }

        return Self.stripMarkdown(fullText)
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
        let maxAttempts = 3
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
                    // Already handled above; re-throw if exhausted
                    lastError = error
                    if attempt < maxAttempts - 1 {
                        continue  // Already slept above
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

    private func buildRequest(prompt: String, context: AIContext?) throws -> URLRequest {
        var messages: [[String: String]] = []
        messages.append(["role": "system", "content": Self.defaultSystemPrompt])
        if let context {
            messages.append(["role": "system", "content": "Search context:\n\(Self.encodeContext(context))"])
        }
        messages.append(["role": "user", "content": prompt])
        return try buildURLRequest(messages: messages)
    }

    private func buildRequest(systemPrompt: String, userMessage: String) throws -> URLRequest {
        try buildURLRequest(messages: [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage],
        ])
    }

    private func buildURLRequest(messages: [[String: String]]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func parseContentDelta(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any]
        else { return nil }
        return delta["content"] as? String
    }

    /// Serialize AIContext into a system message for the chat completions API.
    ///
    /// **Privacy**: Only includes the query string, result count, and up to 20 file
    /// names. Paths and other metadata from ``FileMetadataSummary`` are intentionally
    /// excluded from the API payload. Full metadata is available in the ``AIContext``
    /// but we send only what's needed for the AI to produce useful completions.
    private static func encodeContext(_ context: AIContext) -> String {
        var parts: [String] = []
        parts.append("Query: \(context.query)")
        parts.append("Results: \(context.indexStats.queryResults) files")
        if !context.resultMetadata.isEmpty {
            let names = context.resultMetadata.prefix(20).map(\.name)
            parts.append("Sample files: \(names.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    private static func stripMarkdown(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newlineIdx = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIdx)...])
            }
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt Engineering
    //
    // All prompts in this module follow a consistent pattern:
    // 1. Role definition ("You are a ...")
    // 2. Task description
    // 3. Output format constraint ("Output ONLY X, nothing else")
    // 4. Language support note ("Support both Chinese and English")
    //
    // This pattern is used in: defaultSystemPrompt, searchTranslationSystemPrompt,
    // ResultSummarizer.summarize(), SearchAdvisor.suggest(), SemanticGrouper.group(),
    // CrossLanguageSearch.expandQuery().
    //
    // When modifying prompts, maintain this structure for consistency across providers.

    private static let defaultSystemPrompt = """
        You are an AI assistant helping with file search. Be concise and helpful.
        """

    /// System prompt for the search syntax translation feature.
    ///
    /// Instructs the model to output ONLY valid DeepFinder search syntax with no
    /// markdown formatting. Designed to produce parseable, directly-executable output.
    static let searchTranslationSystemPrompt = """
        You are a search syntax translator for DeepFinder, a macOS file search app.

        Translate the user's natural language query into DeepFinder search syntax.

        DeepFinder search syntax supports:
        - Plain text for substring matching (e.g. "report")
        - ext:pdf or ext:pdf;doc;xls for file extension filtering
        - size:>100mb or size:<1kb for size filtering
        - dm:today, dm:yesterday, dm:lastweek, dm:thismonth, dm:thisyear for date modified
        - path:Documents for path filtering
        - AND, OR for boolean operators
        - | for OR between terms
        - ! for NOT
        - case:exact for case-sensitive matching

        Rules:
        - Output ONLY the search syntax, nothing else.
        - No explanations, no markdown formatting.
        - If the query is ambiguous, make reasonable assumptions.
        - Support both Chinese and English natural language input.
        """
}

// MARK: - Convenience Type Aliases

/// DeepSeek API provider. REQ-3.0-03.
typealias DeepSeekProvider = OpenAICompatibleProvider

extension DeepSeekProvider {
    static func deepSeek(apiKey: String, httpClient: any HTTPClient = URLSessionHTTPClient()) -> DeepSeekProvider {
        DeepSeekProvider(
            name: "deepseek",
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            apiKey: apiKey,
            model: "deepseek-v4-flash",
            httpClient: httpClient
        )
    }
}

/// Qwen (Tongyi Qianwen) API provider. REQ-3.0-04.
typealias QwenProvider = OpenAICompatibleProvider

extension QwenProvider {
    static func qwen(apiKey: String, httpClient: any HTTPClient = URLSessionHTTPClient()) -> QwenProvider {
        QwenProvider(
            name: "qwen",
            endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!,
            apiKey: apiKey,
            model: "qwen-plus",
            httpClient: httpClient
        )
    }
}
