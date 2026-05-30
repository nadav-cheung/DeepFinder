import Foundation

// MARK: - ResultSummarizer

/// Generates a one-sentence summary of search results using an AI model provider.
///
/// Summaries are based solely on `FileMetadataSummary` (no file contents).
/// Results are cached for 5 minutes per identical query to avoid redundant API calls.
/// Returns `nil` when the provider is unavailable or results are empty, ensuring
/// graceful degradation -- callers simply skip displaying the summary.
///
/// REQ-3.0-06: Result Summary
struct ResultSummarizer: Sendable {

    /// The AI provider used for summarization. `nil` means AI is disabled.
    let provider: (any AIModelProvider)?

    /// Cache expiration interval (5 minutes).
    static let cacheTTL: TimeInterval = 300

    /// Simple in-memory cache: query -> (summary, timestamp).
    private let cache: ManagedCache

    init(provider: (any AIModelProvider)?) {
        self.provider = provider
        self.cache = ManagedCache()
    }

    /// Generate a one-sentence summary of search results.
    ///
    /// - Parameters:
    ///   - query: The user's original search query.
    ///   - results: Metadata summaries of the search results.
    /// - Returns: A summary string under 100 characters, or `nil` if unavailable.
    func summarize(query: String, results: [FileMetadataSummary]) async -> String? {
        // No provider configured or no results: nothing to summarize
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

// MARK: - ManagedCache (thread-safe)

/// A simple thread-safe cache for query -> summary mappings.
/// Uses a lock instead of actor to keep ResultSummarizer a plain struct.
private final class ManagedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (value: String, timestamp: Date)] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) < ResultSummarizer.cacheTTL else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func set(_ key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        // Evict expired entries when cache exceeds 100 entries
        if store.count > 100 {
            let now = Date()
            store = store.filter { now.timeIntervalSince($0.value.timestamp) < ResultSummarizer.cacheTTL }
        }
        store[key] = (value, Date())
    }
}
