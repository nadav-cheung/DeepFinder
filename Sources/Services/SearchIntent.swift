import AppIntents

/// AppIntent for searching files via Apple Shortcuts.
///
/// Users can create Shortcuts automations that search DeepFinder and use
/// the resulting file paths in subsequent steps (open, copy path, etc.).
///
/// - Parameter query: The search query string (required).
/// - Parameter limit: Maximum number of results to return (optional, default 20).
/// - Returns: An array of file paths matching the query.
struct SearchFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Files"
    static let description: IntentDescription? = IntentDescription(
        "Search for files by name using DeepFinder and return matching file paths."
    )

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Limit")
    var limit: Int?

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        // Placeholder: returns empty results.
        // Actual daemon IPC connection will be added in a later step.
        return .result(value: [])
    }
}
