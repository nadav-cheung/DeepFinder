import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

// MARK: - SearchAdvisor

/// Suggests a refined search query based on the user's current query and results.
///
/// Uses an AI model provider to generate at most one suggestion. The suggestion
/// is always a valid DeepFinder search syntax string that the user can execute
/// directly.
///
/// **Graceful degradation**: Returns `nil` when:
/// - `provider` is `nil` (AI disabled) -- callers skip showing the suggestion
/// - AI call fails or times out -- same skip behavior
/// - AI returns empty/whitespace text -- same skip behavior
/// Callers should check for `nil` and omit the suggestion UI element.
///
/// REQ-3.0-07: Search Advisor
public struct SearchAdvisor: Sendable {

    /// The AI provider used for generating suggestions. `nil` means AI is disabled.
    public let provider: (any AIModelProvider)?

    public init(provider: (any AIModelProvider)?) {
        self.provider = provider
    }

    /// Generate a single refined search suggestion.
    ///
    /// - Parameters:
    ///   - query: The user's current search query.
    ///   - results: Metadata summaries of the current search results (may be empty).
    ///     Only the first 20 file names are included in the AI prompt.
    /// - Returns: A suggestion string in DeepFinder search syntax, or `nil` if unavailable.
    public func suggest(query: String, results: [FileMetadataSummary]) async -> String? {
        // No provider configured: graceful fallback
        guard let provider else { return nil }

        let fileList = results.prefix(20).map(\.name).joined(separator: ", ")
        let resultDesc = results.isEmpty
            ? "No results found."
            : "Found \(results.count) results. Sample files: \(fileList)"

        let prompt = """
            Given the search query "\(query)" and results (\(resultDesc)), \
            suggest ONE refined search query in \(Product.name) syntax. \
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
