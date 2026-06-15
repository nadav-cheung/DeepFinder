// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - REPLCommand

/// Commands available in the interactive REPL.
///
/// All commands start with a colon (`:`) prefix. Input not starting with
/// `:` is treated as a search query. Commands are case-insensitive.
public enum REPLCommand: String, CaseIterable, Sendable {
    case help
    case quit
    case stats
    case config
    case open
    case reveal
    case daemon
    case explain
    case dataPreview
    case undo
    case bookmark
    case sort
    case filter

    /// One-line help text for each command.
    public var description: String {
        switch self {
        case .help:
            return "Show available commands"
        case .quit:
            return "Exit the REPL"
        case .stats:
            return "Show index statistics (file count, index size, daemon state)"
        case .config:
            return "Get or set a configuration key (:config KEY [VALUE])"
        case .open:
            return "Open result N with the default application (:open N)"
        case .reveal:
            return "Reveal result N in Finder (:reveal N)"
        case .daemon:
            return "Show daemon status (PID, uptime, connections)"
        case .explain:
            return "Show match explanation for result N (:explain N)"
        case .dataPreview:
            return "Show sample data sent to AI providers"
        case .undo:
            return "Undo last file operation"
        case .bookmark:
            return "List, save, or delete search bookmarks (:bm [save NAME | delete N])"
        case .sort:
            return "Set result sort for the session (:sort [relevance|name|date|size|natural] [reverse| clear])"
        case .filter:
            return "Manage saved filter macros (:filter [save NAME EXPR | delete NAME | apply NAME])"
        }
    }

    // MARK: - Parsing

    /// Parse a line of REPL input into a command, arguments, or a query.
    ///
    /// - Parameter input: A single line of user input (trimmed).
    /// - Returns: A tuple of (command, args, isQuery).
    ///   - If the input starts with `:`, attempts to parse as a command.
    ///   - If the command is recognized, returns the command and remaining tokens as args.
    ///   - If the command is unrecognized, returns `(nil, [], false)`.
    ///   - If the input does not start with `:`, returns `(nil, [], true)`.
    ///   - Empty input returns `(nil, [], false)`.
    public static func parse(_ input: String) -> (command: REPLCommand?, args: [String], isQuery: Bool) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, [], false)
        }

        guard trimmed.hasPrefix(":") else {
            return (nil, [], true)
        }

        // Split into tokens: first is the command (with :), rest are args
        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let firstToken = tokens.first else {
            return (nil, [], false)
        }

        let commandStr = String(firstToken.dropFirst()).lowercased()
        let args = Array(tokens.dropFirst())

        // Resolve aliases
        let resolved: String
        switch commandStr {
        case "q":
            resolved = "quit"
        case "h":
            resolved = "help"
        case "bm":
            resolved = "bookmark"
        case "data_preview":
            resolved = "dataPreview"
        default:
            resolved = commandStr
        }

        guard let command = REPLCommand(rawValue: resolved) else {
            return (nil, [], false)
        }

        return (command, args, false)
    }
}
