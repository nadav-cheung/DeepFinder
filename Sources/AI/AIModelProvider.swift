import Foundation

// MARK: - AICapability

/// Capabilities an AI model provider can support.
/// Each case maps to a distinct AI-powered feature in DeepFinder.
enum AICapability: String, Sendable, Codable, CaseIterable {
    /// Translate natural language to search syntax
    case textToSearch
    /// Summarize search results
    case resultSummary
    /// Suggest alternative queries
    case querySuggestion
    /// Analyze user intent behind a query
    case intentAnalysis
    /// Local image analysis via Vision framework
    case localVision
    /// Local speech recognition via Speech framework
    case localSpeech
}

// MARK: - AIError

/// Errors that can occur during AI operations.
enum AIError: Error, Sendable, Equatable {
    /// AI model is not available (disabled or not configured)
    case notAvailable
    /// API rate limit exceeded
    case rateLimited
    /// Response could not be parsed
    case invalidResponse
    /// Request timed out
    case timeout
    /// Network-level error with description
    case networkError(String)
}

// MARK: - AIModelProvider

/// Protocol defining an AI model provider.
///
/// Concrete implementations wrap specific cloud APIs (DeepSeek, Qwen)
/// or local frameworks (Vision, Speech). The protocol is designed so that
/// adding a new provider requires only a single new file -- no changes
/// to existing code.
///
/// Conforms to `Sendable` for Swift 6 strict concurrency safety.
protocol AIModelProvider: Sendable {
    /// Human-readable provider name (e.g. "deepseek", "qwen", "mock").
    var name: String { get }

    /// Set of capabilities this provider supports.
    var capabilities: Set<AICapability> { get }

    /// Stream a completion for the given prompt, optionally with search context.
    ///
    /// Returns an `AsyncThrowingStream` for streaming (token-by-token) responses.
    /// The caller consumes chunks as they arrive; errors propagate through the stream.
    ///
    /// - Parameters:
    ///   - prompt: The user's input text.
    ///   - context: Optional metadata context (never file contents).
    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error>

    /// Translate a natural language query into DeepFinder search syntax.
    ///
    /// Example: "find big videos from last week" -> "ext:mp4;mov;mkv dm:lastweek size:>100mb"
    ///
    /// - Parameter naturalLanguage: The user's natural language input.
    /// - Returns: A valid DeepFinder search syntax string.
    func translateToSearchSyntax(naturalLanguage: String) async throws -> String
}
