import Foundation

// MARK: - NLSearchTranslator

/// Translates natural language queries into DeepFinder search syntax.
///
/// Uses an `AIModelProvider` (cloud or local) to translate freeform input like
/// "find PDF files modified last week" into structured search syntax like
/// `ext:pdf dm:lastweek`. Falls back gracefully when AI is unavailable:
/// returns the input unchanged so the query is treated as a plain substring search.
///
/// REQ-3.0-05: Natural Language Search
struct NLSearchTranslator: Sendable {

    /// The AI provider used for translation. `nil` means AI is disabled.
    let provider: (any AIModelProvider)?

    /// Known search modifier keys extracted from FilterPipeline.parse().
    private static let searchModifierKeys: Set<String> = [
        "size", "ext", "dm", "depth",
        "width", "height", "duration", "pages", "pageCount", "fps", "bitRate",
        "artist", "album", "title", "genre", "codec",
        "file", "folder", "case", "path",
    ]

    init(provider: (any AIModelProvider)?) {
        self.provider = provider
    }

    /// Translate a natural language query into DeepFinder search syntax.
    ///
    /// - If the provider is `nil`, returns the input unchanged (fallback to substring).
    /// - If the input already looks like search syntax, returns it unchanged.
    /// - Otherwise, calls the provider to translate.
    /// - On any error or timeout, returns the input unchanged (graceful fallback).
    func translate(_ naturalLanguage: String) async -> String {
        // Empty input: nothing to translate
        guard !naturalLanguage.isEmpty else { return "" }

        // No AI provider configured: plain substring search
        guard let provider else { return naturalLanguage }

        // Input already looks like search syntax: don't re-translate
        if looksLikeSearchSyntax(naturalLanguage) { return naturalLanguage }

        // Attempt AI translation; fall back on any failure
        do {
            return try await provider.translateToSearchSyntax(naturalLanguage: naturalLanguage)
        } catch {
            return naturalLanguage
        }
    }

    // MARK: - Private

    /// Detect whether the input already contains search operators.
    ///
    /// Returns `true` if the input contains any recognized modifier prefix
    /// (`ext:`, `size:`, `dm:`, etc.) or boolean operators (`AND`, `OR`, `|`).
    private func looksLikeSearchSyntax(_ input: String) -> Bool {
        // Check for modifier prefixes like "ext:", "size:", "dm:"
        for key in Self.searchModifierKeys {
            if input.contains("\(key):") {
                return true
            }
        }

        // Check for regex: prefix
        if input.contains("regex:") {
            return true
        }

        // Check for boolean operators (word-bounded AND/OR, or pipe)
        let upper = input.uppercased()
        if upper.contains(" AND ") || upper.contains(" OR ") {
            return true
        }
        if input.contains("|") {
            return true
        }

        // Check for NOT prefix
        if input.hasPrefix("!") {
            return true
        }

        return false
    }
}
