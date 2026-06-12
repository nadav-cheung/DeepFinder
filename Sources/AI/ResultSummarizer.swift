// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

// MARK: - ResultSummarizer

/// Generates a one-sentence summary of search results using an AI model provider.
///
/// Summaries are based solely on `FileMetadataSummary` (no file contents).
/// Results are cached for 5 minutes per identical query to avoid redundant API calls.
///
/// **Graceful degradation**: Returns `nil` when:
/// - `provider` is `nil` (AI disabled) -- callers simply skip displaying the summary
/// - `results` is empty -- nothing to summarize
/// - AI call fails or returns empty text -- same skip behavior
/// Callers should check for `nil` and omit the summary UI element.
///
/// REQ-3.0-06: Result Summary
public struct ResultSummarizer: Sendable {

    /// The AI provider used for summarization. `nil` means AI is disabled.
    public let provider: (any AIModelProvider)?

    /// Cache expiration interval (5 minutes).
    /// Prevents redundant API calls for repeated queries within a short session.
    public static let cacheTTL: TimeInterval = Constants.AI.summarizerCacheTTL

    /// Thread-safe, bounded cache. See `ManagedCache` below for implementation details.
    private let cache: ManagedCache

    public init(provider: (any AIModelProvider)?) {
        self.provider = provider
        self.cache = ManagedCache()
    }

    /// Generate a one-sentence summary of search results.
    ///
    /// - Parameters:
    ///   - query: The user's original search query.
    ///   - results: Metadata summaries of the search results. Only the first 30
    ///     are included in the AI prompt to bound token usage.
    /// - Returns: A summary string, or `nil` if unavailable (see graceful degradation above).
    public func summarize(query: String, results: [FileMetadataSummary]) async -> String? {
        // No provider configured or no results: graceful fallback
        guard let provider, !results.isEmpty else { return nil }

        // Check cache
        if let cached = cache.get(query) { return cached }

        // Build prompt
        let fileList = results.prefix(30).map { summary in
            "\(summary.name) (\(summary.extension ?? "?"), \(formatSize(summary.size)))"
        }.joined(separator: ", ")

        let prompt = """
            Summarize these search results in ONE sentence under 100 characters. \
            Query: "\(query)". Files: \(fileList). Total: \(results.count) files.
            """

        let context = AIContext(
            query: query,
            resultMetadata: Array(results.prefix(30)),
            indexStats: .init(totalFiles: 0, queryResults: results.count)
        )

        // Call provider and collect full response
        do {
            var fullText = ""
            for try await chunk in provider.complete(prompt: prompt, context: context) {
                fullText += chunk
            }
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            cache.set(query, value: trimmed)
            return trimmed
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func formatSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return "\(bytes / 1_073_741_824)GB" }
        if bytes >= 1_048_576 { return "\(bytes / 1_048_576)MB" }
        if bytes >= 1024 { return "\(bytes / 1024)KB" }
        return "\(bytes)B"
    }
}

// MARK: - ManagedCache (thread-safe, bounded)

/// A thread-safe, bounded cache for query -> summary mappings.
///
/// **Thread safety**: Uses `NSLock` (not actor) so that `ResultSummarizer` remains
/// a plain struct. Lock is held for the minimum scope (get/set) with `defer { unlock() }`.
///
/// **Bounded**: Caps at 100 entries. When exceeded, expired entries are evicted en masse.
/// If all entries are still within TTL, the cache temporarily exceeds 100 until entries
/// expire naturally. TTL-based expiry prevents unbounded growth over time.
///
/// **TTL**: Controlled by `ResultSummarizer.cacheTTL` (5 minutes). Entries are lazily
/// evicted on access (`get` checks TTL) or proactively evicted when the cache exceeds
/// 100 entries (`set` triggers full sweep).
private final class ManagedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (value: String, timestamp: Date)] = [:]

    /// Maximum entries before triggering proactive eviction.
    private static let maxEntries = Constants.AI.summarizerCacheMaxEntries

    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) < ResultSummarizer.cacheTTL else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    public func set(_ key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        if store.count > Self.maxEntries {
            let now = Date()
            store = store.filter { now.timeIntervalSince($0.value.timestamp) < ResultSummarizer.cacheTTL }
        }
        store[key] = (value, Date())
    }
}
