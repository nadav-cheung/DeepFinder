import Foundation

// MARK: - OpenAICompatibleProvider

/// A generic AI model provider for OpenAI-compatible chat completions APIs.
///
/// Shared implementation for providers that use the same SSE streaming format
/// (DeepSeek, Qwen, and any future OpenAI-compatible endpoint).
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

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try buildRequest(prompt: prompt, context: context)
                    let response = try await httpClient.perform(request)

                    if response.statusCode == 429 {
                        continuation.finish(throwing: AIError.rateLimited)
                        return
                    }
                    if response.statusCode >= 400 {
                        continuation.finish(throwing: AIError.networkError("HTTP \(response.statusCode)"))
                        return
                    }

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

    private static let defaultSystemPrompt = """
        You are an AI assistant helping with file search. Be concise and helpful.
        """

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
