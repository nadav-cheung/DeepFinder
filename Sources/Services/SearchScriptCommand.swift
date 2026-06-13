// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderDaemon

// MARK: - LockedBox

/// A simple mutex-protected mutable box for bridging async results to sync contexts.
/// Used by ``DeepFinderSearchCommand`` to safely pass IPC results through a semaphore.
final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    public init(_ value: T) {
        _value = value
    }

    public var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - SearchScriptError

/// Errors thrown during AppleScript search command execution.
public enum SearchScriptError: Error {
    case ipcTimeout
}

// MARK: - SearchScriptResult

/// The result of an AppleScript `search` command.
///
/// Contains an array of file paths matching the query.
/// When the daemon is unavailable, `paths` is empty.
public struct SearchScriptResult: Sendable, Equatable {
    public let paths: [String]
}

// MARK: - SearchScriptParser

/// Pure helper for parsing AppleScript command arguments.
///
/// Extracted from ``DeepFinderSearchCommand`` for testability without
/// requiring a live `NSScriptCommand` instance.
public enum SearchScriptParser {
    /// Extract the search query from an NSScriptCommand-style arguments dictionary.
    ///
    /// The key `"DirectParameter"` holds the direct parameter of the AppleScript command
    /// (e.g. `search "report"` -- the string `"report"` is the direct parameter).
    ///
    /// - Parameter arguments: The command arguments dictionary.
    /// - Returns: The trimmed query string, or `nil` if absent, empty, or not a String.
    public static func extractQuery(from arguments: [String: Any]) -> String? {
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
public class DeepFinderSearchCommand: NSScriptCommand {

    /// Perform the search synchronously and return results.
    ///
    /// Separated from `performDefaultImplementation()` for testability.
    /// - Parameter query: The search query string, or `nil` if none was provided.
    /// - Returns: A ``SearchScriptResult`` with matching file paths.
    public static func performSearch(query: String?) -> SearchScriptResult {
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
    public override func performDefaultImplementation() -> Any? {
        let query = SearchScriptParser.extractQuery(from: directParameter != nil
            ? ["DirectParameter": directParameter as Any]
            : [:])
        let result = Self.performSearch(query: query)
        return result.paths
    }
}

// MARK: - FileInfoScriptResult

/// The result of an AppleScript `get-file-info` command.
///
/// Contains a dictionary of file metadata, or an empty dictionary when the file is not found.
public struct FileInfoScriptResult: Sendable, Equatable {
    public let info: [String: String]
}

// MARK: - FileInfoScriptParser

/// Pure helper for parsing AppleScript `get-file-info` command arguments.
///
/// Extracted from ``DeepFinderGetFileInfoCommand`` for testability without
/// requiring a live `NSScriptCommand` instance.
public enum FileInfoScriptParser {
    /// Extract the file path from an NSScriptCommand-style arguments dictionary.
    ///
    /// The key `"DirectParameter"` holds the direct parameter of the AppleScript command
    /// (e.g. `get file info "/Users/test/report.pdf"` -- the string is the direct parameter).
    ///
    /// - Parameter arguments: The command arguments dictionary.
    /// - Returns: The trimmed path string, or `nil` if absent, empty, or not a String.
    public static func extractPath(from arguments: [String: Any]) -> String? {
        guard let raw = arguments["DirectParameter"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - DeepFinderGetFileInfoCommand

/// NSScriptCommand subclass handling the AppleScript `get file info` command.
///
/// Usage from AppleScript:
/// ```applescript
/// tell application "DeepFinder" to get file info "/Users/test/report.pdf"
/// ```
///
/// The sdef script dictionary maps the `get-file-info` command to this class.
/// Returns file metadata (name, size, dates, type) for the given path.
public class DeepFinderGetFileInfoCommand: NSScriptCommand {

    /// Perform the file info lookup synchronously and return results.
    ///
    /// Separated from `performDefaultImplementation()` for testability.
    /// - Parameter path: The file path string, or `nil` if none was provided.
    /// - Returns: A ``FileInfoScriptResult`` with file metadata.
    public static func performFileInfo(path: String?) -> FileInfoScriptResult {
        guard let path, !path.isEmpty else {
            return FileInfoScriptResult(info: [:])
        }

        let client = IPCClient(socketPath: Product.socketPath)
        // Match the EXACT path among results so we never return a different file whose
        // name matches the path-as-query string. A larger limit gives the exact file a
        // chance to appear; an exact-path IPC case is the fully-correct future fix.
        let request: IPCRequest = .query(path, limit: 50)

        let box = LockedBox<FileInfoScriptResult>(FileInfoScriptResult(info: [:]))
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let response = try await client.send(request)
                switch response {
                case .results(let results, _) where !results.isEmpty:
                    if let match = results.first(where: { $0.record.path == path }) {
                        box.value = FileInfoScriptResult(info: GetFileInfoIntent.metadataDict(from: match.record))
                    }
                default:
                    break
                }
            } catch {
                // Daemon unavailable — return empty results
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 5) == .success else {
            return FileInfoScriptResult(info: [:])
        }
        return box.value
    }

    /// NSScriptCommand entry point. Called by the Apple Events framework.
    public override func performDefaultImplementation() -> Any? {
        let path = FileInfoScriptParser.extractPath(from: directParameter != nil
            ? ["DirectParameter": directParameter as Any]
            : [:])
        let result = Self.performFileInfo(path: path)
        return result.info
    }
}
