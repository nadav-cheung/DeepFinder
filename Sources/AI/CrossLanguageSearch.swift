/// Expands queries with cross-language synonyms (Chinese to English and vice versa).
///
/// Enables finding "mockup_final.fig" when searching for "设计稿". Results are
/// locally cached with TTL-based expiry. Gracefully degrades to empty when AI is off.
import Foundation

// MARK: - CrossLanguageSearch

/// Expands a search query with cross-language synonyms and translations.
///
/// Given a Chinese query like "设计稿", returns English synonyms such as
/// "mockup", "design", "prototype" so that files like "mockup_final.fig"
/// are also matched. Similarly, an English query like "mockup" returns
/// Chinese translations so that Chinese-named files are found.
///
/// Results are cached locally — identical queries reuse the cached expansion
/// without calling the AI provider again. When no provider is configured,
/// returns an empty array, allowing graceful fallback to pinyin + substring
/// matching.
///
/// REQ-3.0-13: Cross-Language Search
struct CrossLanguageSearch: Sendable {

    /// The AI provider used for translation/synonym generation. `nil` means AI is disabled.
    let provider: (any AIModelProvider)?

    /// Thread-safe cache: query -> expanded terms.
    private let cache: ManagedTermCache

    init(provider: (any AIModelProvider)?) {
        self.provider = provider
        self.cache = ManagedTermCache()
    }

    /// Expand a query with cross-language synonyms and translations.
    ///
    /// **Graceful degradation**: Returns an empty array when:
    /// - `provider` is `nil` (AI disabled) -- callers fall back to pinyin + substring matching
    /// - AI call fails -- same fallback behavior
    /// - AI returns no parseable terms -- same fallback behavior
    /// The caller always gets a valid (possibly empty) array; never crashes.
    ///
    /// - Parameter query: The user's search query (Chinese or English).
    /// - Returns: An array of expanded terms, or empty if unavailable.
    func expandQuery(_ query: String) async -> [String] {
        // No provider configured: graceful fallback to pinyin + substring matching
        guard let provider else { return [] }

        // Check cache
        if let cached = cache.get(query) { return cached }

        let prompt = """
            Given the search query "\(query)", provide cross-language synonyms and translations \
            that would help find related files. If the query is Chinese, provide English synonyms. \
            If the query is English, provide Chinese translations.
            Output ONLY a comma-separated list of terms, nothing else. No explanations, no markdown.
            """

        let context = AIContext(
            query: query,
            resultMetadata: [],
            indexStats: .init(totalFiles: 0, queryResults: 0)
        )

        do {
            var fullText = ""
            for try await chunk in provider.complete(prompt: prompt, context: context) {
                fullText += chunk
            }

            let terms = parseCommaSeparatedTerms(fullText)
            guard !terms.isEmpty else { return [] }

            cache.set(query, value: terms)
            return terms
        } catch {
            return []
        }
    }

    // MARK: - Private

    /// Parse a comma-separated string into trimmed, non-empty terms.
    private func parseCommaSeparatedTerms(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - ManagedTermCache (thread-safe, bounded)

/// A thread-safe, bounded cache for query -> term array mappings.
///
/// **Thread safety**: Uses `NSLock` (not actor) so that `CrossLanguageSearch` remains
/// a plain struct. Lock is held for the minimum scope (get/set) with `defer { unlock() }`.
///
/// **Bounded**: Caps at 100 entries. When exceeded, expired entries are evicted en masse.
/// If all entries are still within TTL, the cache temporarily exceeds 100 until entries
/// expire naturally. This is intentional -- TTL-based expiry prevents unbounded growth
/// over time, and the eviction-on-set policy avoids expensive eviction on every write.
///
/// **TTL**: 1 hour. Entries are lazily evicted on access (`get` checks TTL) or
/// proactively evicted when the cache exceeds 100 entries (`set` triggers full sweep).
private final class ManagedTermCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (value: [String], timestamp: Date)] = [:]

    /// TTL for cached entries (1 hour).
    private static let ttl: TimeInterval = Constants.AI.crossLanguageCacheTTL

    /// Maximum entries before triggering proactive eviction.
    private static let maxEntries = Constants.AI.crossLanguageCacheMaxEntries

    func get(_ key: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) < Self.ttl else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func set(_ key: String, value: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if store.count > Self.maxEntries {
            let now = Date()
            store = store.filter { now.timeIntervalSince($0.value.timestamp) < Self.ttl }
        }
        store[key] = (value, Date())
    }
}
