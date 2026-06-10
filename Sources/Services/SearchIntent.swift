import AppIntents
import DeepFinderIndex
import DeepFinderDaemon

/// AppIntent for searching files via Apple Shortcuts.
///
/// Users can create Shortcuts automations that search DeepFinder and use
/// the resulting file paths in subsequent steps (open, copy path, etc.).
///
/// - Parameter query: The search query string (required).
/// - Parameter limit: Maximum number of results to return (optional, default 20).
/// - Returns: An array of file paths matching the query.
public struct SearchFilesIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Search Files"
    public static let description: IntentDescription? = IntentDescription(
        "Search for files by name using \(Product.name) and return matching file paths."
    )

    @Parameter(title: "Query")
    public var query: String

    @Parameter(title: "Limit")
    public var limit: Int?

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
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

// MARK: - GetFileInfoIntent

/// AppIntent for retrieving metadata about a single file via Apple Shortcuts.
///
/// Given a file path, returns a JSON string containing file metadata:
/// name, size, creation date, modification date, extension, and whether it is a directory.
///
/// - Parameter path: The absolute file path (required).
/// - Returns: A JSON string of file metadata, or an empty string if not found.
public struct GetFileInfoIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Get File Info"
    public static let description: IntentDescription? = IntentDescription(
        "Get metadata for a file by its path using \(Product.name). Returns a JSON string with name, size, dates, and type."
    )

    @Parameter(title: "File Path")
    public var path: String

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let client = IPCClient(socketPath: Product.socketPath)
        let request: IPCRequest = .query(path, limit: 1)
        let response: IPCResponse
        do {
            response = try await client.send(request)
        } catch {
            return .result(value: "")
        }
        switch response {
        case .results(let results, _) where !results.isEmpty:
            let record = results[0].record
            let json = Self.metadataJSON(from: record)
            return .result(value: json)
        default:
            return .result(value: "")
        }
    }

    /// Convert a FileRecord to a JSON string for Shortcuts consumption.
    public static func metadataJSON(from record: FileRecord) -> String {
        let dict = metadataDict(from: record)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Convert a FileRecord to a flat string dictionary.
    public static func metadataDict(from record: FileRecord) -> [String: String] {
        var info: [String: String] = [
            "name": record.originalName,
            "path": record.path,
            "size": String(record.size),
            "isDirectory": record.isDirectory ? "true" : "false",
            "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
            "modifiedAt": ISO8601DateFormatter().string(from: record.modifiedAt),
        ]
        if let ext = record.extension {
            info["extension"] = ext
        }
        return info
    }
}
