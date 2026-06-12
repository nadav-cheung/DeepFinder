// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # AI Module
///
/// Privacy-first AI features that enhance search without compromising file privacy.
/// All cloud API calls are opt-in; local features (Vision, Speech) run entirely on-device.
///
/// ## Components
/// - ``AIModelProvider`` -- protocol for AI backends (cloud APIs and local frameworks)
/// - ``AICapability`` -- enum of feature capabilities a provider can support
/// - ``AIConfig`` -- user-facing configuration for AI features (enabled, provider, API key)
/// - ``AIContext`` -- search context passed to AI providers (metadata only, never file contents)
/// - ``OpenAICompatibleProvider`` -- generic provider for OpenAI-compatible chat completions APIs
/// - ``DeepSeekProvider`` -- DeepSeek API integration (typealias + factory)
/// - ``QwenProvider`` -- Qwen API integration (typealias + factory)
/// - ``AnthropicProvider`` -- Claude Messages API integration
/// - ``LocalVisionProvider`` -- on-device image analysis via Vision framework
/// - ``LocalSpeechProvider`` -- on-device speech recognition via Speech framework
/// - ``NLSearchTranslator`` -- natural language to search syntax translation
/// - ``ResultSummarizer`` -- LLM-powered search result summarization
/// - ``SearchAdvisor`` -- intelligent query suggestions and refinements
/// - ``MatchExplainer`` -- explains why a file matched a query (local, no AI required)
/// - ``SemanticGrouper`` -- groups search results by semantic similarity
/// - ``CrossLanguageSearch`` -- cross-language search (e.g., search Chinese names in English)
/// - ``ClipboardSearch`` -- searches for clipboard content in the index
/// - ``ImageSimilaritySearch`` -- finds visually similar images via on-device embeddings
/// - ``FileMetadataSummary`` -- privacy-safe metadata summary for AI consumption
/// - ``NLOperations`` -- safe natural-language file operation parsing
/// - ``HTTPClient`` -- minimal HTTP client for AI API calls
///
/// ## Privacy Model
///
/// The AI module enforces a strict privacy boundary:
///
/// 1. **Compile-time boundary**: ``AIContext`` and ``FileMetadataSummary`` are the ONLY types
///    that cross into AI providers. They contain metadata (name, size, date, extension) but
///    never file contents, thumbnails, or binary data. This is enforced by the type system --
///    ``AIContext`` cannot access ``FileRecord``'s raw fields except through
///    ``FileMetadataSummary.from(_:)`` which performs optional path anonymization.
///
/// 2. **Runtime boundary**: ``AIConfig.defaults`` sets all AI features OFF by default.
///    The user must explicitly `deepfinder config set ai.enabled true` and provide an API key.
///    Local-only features (Vision, Speech) default to enabled since they never leave the device.
///
/// 3. **Path anonymization**: By default, `/Users/<username>/` prefixes are replaced with `~/`
///    before metadata is sent to any cloud provider. Controlled by `ai.pathAnonymization`.
///
/// 4. **Metadata sending opt-in**: The `ai.sendMetadata` config (default `false`) controls
///    whether result metadata is included in AI prompts. When off, only the query string
///    is sent.
///
/// **Local features** (Vision, Speech, ImageSimilaritySearch): zero data leaves the device.
/// **Cloud features**: only file metadata is sent -- never file contents.
///
/// ## Capability System
///
/// Each ``AIModelProvider`` declares a `Set<AICapability>` describing which features it supports.
/// This allows the system to:
/// - Skip features the active provider doesn't support (e.g., a text-only provider won't
///   be asked for `localVision`)
/// - Mix providers: a text provider for search translation + local Vision for image analysis
/// - Gracefully degrade: all consumers return `nil` or empty when `provider` is `nil`
///
/// Feature files (ResultSummarizer, SearchAdvisor, etc.) accept `(any AIModelProvider)?`.
/// When `nil`, they silently return `nil`/empty results, so callers simply skip the AI
/// enhancement without any code changes.
///
/// ## Adding a New Provider
/// 1. Create a new file implementing ``AIModelProvider``
/// 2. If the provider uses the OpenAI chat completions API format, instantiate
///    ``OpenAICompatibleProvider`` with the appropriate endpoint and model name
/// 3. Declare supported ``AICapability`` values
/// 4. Register in ``AIConfig`` -- no changes to existing code needed
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

// MARK: - AICapability

/// Capabilities an AI model provider can support.
/// Each case maps to a distinct AI-powered feature in DeepFinder.
public enum AICapability: String, Sendable, Codable, CaseIterable {
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
    /// On-device text AI (FoundationModels LanguageModelSession)
    case onDeviceTextAI
}

// MARK: - AIError

/// Errors that can occur during AI operations.
public enum AIError: Error, Sendable, Equatable {
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
public protocol AIModelProvider: Sendable {
    /// Human-readable provider name (e.g. "deepseek", "qwen", "mock").
    var name: String { get }

    /// Set of capabilities this provider supports.
    var capabilities: Set<AICapability> { get }

    /// User-facing display name for UI/CLI (e.g., "Qwen Cloud", "Claude (Anthropic)").
    var displayName: String { get }

    /// Whether this provider runs entirely on-device (no network).
    /// Default false. AppleOnDeviceProvider overrides to true.
    var supportsOnDevice: Bool { get }

    /// Maximum token count for the context window.
    /// Used by callers to truncate file lists before sending.
    var contextLimit: Int { get }

    /// Whether this provider has a companion Embedding API.
    /// Used by ProviderRegistry to decide embedding routing.
    var hasEmbeddingAPI: Bool { get }

    /// Stream a completion for the given prompt, optionally with search context.
    ///
    /// Returns an `AsyncThrowingStream` for streaming (token-by-token) responses.
    /// The caller consumes chunks as they arrive; errors propagate through the stream's
    /// terminal event (`.failure`). Callers should use `for try await` and catch errors
    /// at the iteration site, falling back gracefully (e.g., returning `nil`).
    ///
    /// **Error propagation**: The stream may finish with:
    /// - `AIError.rateLimited` (HTTP 429)
    /// - `AIError.networkError` (HTTP 4xx/5xx, transport failures)
    /// - `CancellationError` (if the consuming Task is cancelled mid-stream)
    ///
    /// - Parameters:
    ///   - prompt: The user's input text.
    ///   - context: Optional metadata context. **Privacy**: contains only file metadata
    ///     (names, sizes, dates, extensions) -- never file contents. See ``AIContext``.
    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error>

    /// Translate a natural language query into DeepFinder search syntax.
    ///
    /// Example: "find big videos from last week" -> "ext:mp4;mov;mkv dm:lastweek size:>100mb"
    ///
    /// - Parameter naturalLanguage: The user's natural language input.
    /// - Returns: A valid DeepFinder search syntax string.
    func translateToSearchSyntax(naturalLanguage: String) async throws -> String
}

// MARK: - AIModelProvider Defaults

extension AIModelProvider {
    public var displayName: String { name }
    public var supportsOnDevice: Bool { false }
    public var contextLimit: Int { 128_000 }
    public var hasEmbeddingAPI: Bool { false }
}
