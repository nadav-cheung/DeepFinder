import Foundation

// MARK: - SearchAdvisor

/// Suggests a refined search query based on the user's current query and results.
///
/// Uses an AI model provider to generate at most one suggestion. The suggestion
/// is always a valid DeepFinder search syntax string that the user can execute
/// directly. Returns `nil` when the provider is unavailable, ensuring graceful
/// degradation -- callers simply skip showing the suggestion.
///
/// REQ-3.0-07: Search Advisor
struct SearchAdvisor: Sendable {

    /// The AI provider used for generating suggestions. `nil` means AI is disabled.
    let provider: (any AIModelProvider)?

    init(provider: (any AIModelProvider)?) {
        self.provider = provider
    }

    /// Generate a single refined search suggestion.
    ///
    /// - Parameters:
    ///   - query: The user's current search query.
    ///   - results: Metadata summaries of the current search results (may be empty).
    /// - Returns: A suggestion string, or `nil` if unavailable.
    func suggest(query: String, results: [FileMetadataSummary]) async -> String? {
        // No provider configured: no suggestion
        guard let provider else { return nil }

        let fileList = results.prefix(20).map(\.name).joined(separator: ", ")
        let resultDesc = results.isEmpty
            ? "No results found."
            : "Found \(results.count) results. Sample files: \(fileList)"

        let prompt = """
            Given the search query "\(query)" and results (\(resultDesc)), \
            suggest ONE refined search query in DeepFinder syntax. \
            Output ONLY the suggested search syntax, nothing else. \
            No explanations, no markdown.
            """

        let context = AIContext(
            query: query,
            resultMetadata: Array(results.prefix(20)),
            indexStats: .init(totalFiles: 0, queryResults: results.count)
        )

        do {
            var fullText = ""
            for try await chunk in provider.complete(prompt: prompt, context: context) {
                fullText += chunk
            }
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }
}
