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
        let client = IPCClient(socketPath: Product.socketPath)
        let request: IPCRequest = .query(query, limit: limit ?? 20)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            return .result(value: [])
        }
        switch response {
        case .results(let results, _):
            let paths = results.map(\.record.path)
            return .result(value: paths)
        default:
            return .result(value: [])
        }
    }
}
