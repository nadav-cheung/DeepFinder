import Foundation

// MARK: - LockedBox

/// A simple mutex-protected mutable box for bridging async results to sync contexts.
/// Used by ``DeepFinderSearchCommand`` to safely pass IPC results through a semaphore.
final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        _value = value
    }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - SearchScriptError

/// Errors thrown during AppleScript search command execution.
enum SearchScriptError: Error {
    case ipcTimeout
}

// MARK: - SearchScriptResult

/// The result of an AppleScript `search` command.
///
/// Contains an array of file paths matching the query.
/// When the daemon is unavailable, `paths` is empty.
struct SearchScriptResult: Sendable, Equatable {
    let paths: [String]
}

// MARK: - SearchScriptParser

/// Pure helper for parsing AppleScript command arguments.
///
/// Extracted from ``DeepFinderSearchCommand`` for testability without
/// requiring a live `NSScriptCommand` instance.
enum SearchScriptParser {
    /// Extract the search query from an NSScriptCommand-style arguments dictionary.
    ///
    /// The key `"DirectParameter"` holds the direct parameter of the AppleScript command
    /// (e.g. `search "report"` -- the string `"report"` is the direct parameter).
    ///
    /// - Parameter arguments: The command arguments dictionary.
    /// - Returns: The trimmed query string, or `nil` if absent, empty, or not a String.
    static func extractQuery(from arguments: [String: Any]) -> String? {
        guard let raw = arguments["DirectParameter"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - DeepFinderSearchCommand

/// NSScriptCommand subclass handling the AppleScript `search` command.
///
/// Usage from AppleScript:
/// ```applescript
/// tell application "DeepFinder" to search "report"
/// ```
///
/// The sdef script dictionary maps the `search` command to this class.
/// Placeholder implementation returns empty results; actual daemon IPC
/// will be connected once the integration layer is finalized.
class DeepFinderSearchCommand: NSScriptCommand {

    /// Perform the search synchronously and return results.
    ///
    /// Separated from `performDefaultImplementation()` for testability.
    /// - Parameter query: The search query string, or `nil` if none was provided.
    /// - Returns: A ``SearchScriptResult`` with matching file paths.
    static func performSearch(query: String?) -> SearchScriptResult {
        guard let query, !query.isEmpty else {
            return SearchScriptResult(paths: [])
        }

        let client = IPCClient(socketPath: Product.socketPath)
        let request: IPCRequest = .query(query, limit: 20)

        let box = LockedBox<SearchScriptResult>(SearchScriptResult(paths: []))
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let response = try await client.send(request)
                switch response {
                case .results(let results, _):
                    box.value = SearchScriptResult(paths: results.map(\.record.path))
                default:
                    break
                }
            } catch {
                // Daemon unavailable — return empty results
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            return SearchScriptResult(paths: [])
        }
        return box.value
    }

    /// NSScriptCommand entry point. Called by the Apple Events framework.
    override func performDefaultImplementation() -> Any? {
        let query = SearchScriptParser.extractQuery(from: directParameter != nil
            ? ["DirectParameter": directParameter as Any]
            : [:])
        let result = Self.performSearch(query: query)
        return result.paths
    }
}
