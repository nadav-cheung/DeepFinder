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
    /// - Parameter query: The user's search query (Chinese or English).
    /// - Returns: An array of expanded terms, or empty if unavailable.
    func expandQuery(_ query: String) async -> [String] {
        // No provider configured: return empty (fallback to pinyin + substring)
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

// MARK: - ManagedTermCache (thread-safe)

/// A simple thread-safe cache for query -> term array mappings.
/// Uses a lock instead of actor to keep CrossLanguageSearch a plain struct.
private final class ManagedTermCache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: [String]] = [:]

    func get(_ key: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func set(_ key: String, value: [String]) {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
    }
}
