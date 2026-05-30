import Foundation

// MARK: - NLOperationType

/// Safe file operations that can be triggered via natural language commands.
///
/// Deliberately excludes destructive operations (delete, remove, trash).
/// Only move, copy, and rename are permitted — the user can always undo
/// these via Finder or Terminal.
///
/// REQ-3.0-14: Natural Language Operations
enum NLOperationType: String, Sendable, Codable, CaseIterable, Equatable {
    case move
    case copy
    case rename
}

// MARK: - NLOperation

/// A parsed natural-language file operation.
///
/// Represents an intent like "move photos to /Volumes/Backup" that has been
/// extracted from freeform text but not yet executed. The `preview` field
/// lists the file paths that would be affected, so the user can confirm
/// before any filesystem changes occur.
struct NLOperation: Sendable, Equatable {
    let type: NLOperationType
    let sourcePattern: String
    let destination: String
    let preview: [String]
}

// MARK: - NLOperations

/// Parses natural language commands into safe file operations.
///
/// Recognizes patterns like "move X to Y", "copy X to Y", "rename X to Y".
/// Returns `nil` for destructive commands (delete, remove, rm) or
/// unrecognized input -- the system never auto-executes file deletion.
///
/// **Safety model**: Only move, copy, and rename are permitted. The user can
/// always undo these via Finder or Terminal. Destructive verbs are rejected
/// immediately at parse time, before any file matching occurs. Operations are
/// never auto-executed -- the `preview` field is shown to the user for
/// confirmation before any filesystem changes.
///
/// **No AI required**: Uses simple pattern matching, no cloud or local AI provider.
///
/// REQ-3.0-14: Natural Language Operations
struct NLOperations: Sendable {

    /// Words that signal a destructive intent. If any of these appear at the
    /// start of the command, `parse()` returns `nil` immediately.
    /// This is a denylist approach -- only known-safe verbs are accepted.
    static let destructiveVerbs: Set<String> = [
        "delete", "remove", "rm", "erase", "trash", "shred", "unlink",
    ]

    /// Parse a natural language command into an `NLOperation`, if it matches
    /// a recognized safe-operation pattern.
    ///
    /// Returns `nil` for:
    /// - Empty or whitespace-only input
    /// - Destructive commands (delete, remove, rm, ...)
    /// - Unrecognized sentence structure
    func parse(_ input: String) -> NLOperation? {
        return parseNLCommand(input)
    }

    /// Generate a preview of files matching the operation's source pattern.
    ///
    /// Performs case-insensitive substring matching against the file paths.
    func preview(operation: NLOperation, availableFiles: [String]) -> [String] {
        return generatePreview(operation: operation, availableFiles: availableFiles)
    }
}

// MARK: - Free functions (testable entry points)

/// Parse a natural language command into a safe file operation.
///
/// Recognized patterns:
///   "move <pattern> to <destination>"
///   "copy <pattern> to <destination>"
///   "rename <pattern> to <destination>"
///
/// Returns `nil` for destructive verbs, empty input, or unrecognized syntax.
func parseNLCommand(_ input: String) -> NLOperation? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // First word determines intent
    let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard let firstWord = words.first else { return nil }
    let verb = firstWord.lowercased()

    // Reject destructive verbs immediately
    if NLOperations.destructiveVerbs.contains(verb) {
        return nil
    }

    // Map verb to operation type
    let opType: NLOperationType
    switch verb {
    case "move":
        opType = .move
    case "copy":
        opType = .copy
    case "rename":
        opType = .rename
    default:
        return nil
    }

    // Rest of the string after the verb
    let afterVerb = String(trimmed.dropFirst(firstWord.count)).trimmingCharacters(in: .whitespaces)

    // Split on " to " to separate source pattern from destination
    guard let separatorRange = afterVerb.range(of: " to ", options: [.caseInsensitive]) else {
        return nil
    }

    let sourcePattern = String(afterVerb[afterVerb.startIndex..<separatorRange.lowerBound])
        .trimmingCharacters(in: .whitespaces)
    let destination = String(afterVerb[separatorRange.upperBound...])
        .trimmingCharacters(in: .whitespaces)

    guard !sourcePattern.isEmpty, !destination.isEmpty else { return nil }

    return NLOperation(type: opType, sourcePattern: sourcePattern, destination: destination, preview: [])
}

/// Filter available file paths by case-insensitive substring match against
/// the operation's source pattern.
///
/// Used to generate a preview of which files would be affected before the
/// user confirms the operation.
func generatePreview(operation: NLOperation, availableFiles: [String]) -> [String] {
    let pattern = operation.sourcePattern.lowercased()
    return availableFiles.filter { $0.lowercased().contains(pattern) }
}
