import Foundation

// MARK: - FileManagerProvider

/// Abstraction over FileManager for testability.
///
/// REQ-3.0-14: Actual file operation execution
protocol FileManagerProvider: Sendable {
    func moveItem(at src: URL, to dst: URL) throws
    func copyItem(at src: URL, to dst: URL) throws
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws
    func fileExists(atPath path: String) -> Bool
    func removeItem(at url: URL) throws
}

/// Production implementation wrapping `FileManager.default`.
///
/// Marked `@unchecked Sendable` because `FileManager.default` is a
/// thread-safe singleton, but the type system cannot prove it.
struct SystemFileManagerProvider: FileManagerProvider, @unchecked Sendable {
    nonisolated(unsafe) private let fm = FileManager.default

    func moveItem(at src: URL, to dst: URL) throws {
        try fm.moveItem(at: src, to: dst)
    }

    func copyItem(at src: URL, to dst: URL) throws {
        try fm.copyItem(at: src, to: dst)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }

    func fileExists(atPath path: String) -> Bool {
        fm.fileExists(atPath: path)
    }

    func removeItem(at url: URL) throws {
        try fm.removeItem(at: url)
    }
}

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

// MARK: - NLOperationRecord

/// A record of a previously executed operation, stored for undo support.
///
/// `originalPaths` maps each destination path back to its source path before
/// the operation ran, enabling undo (move back, remove copy, rename back).
///
/// REQ-3.0-14: Undo support
struct NLOperationRecord: Sendable, Equatable {
    let operation: NLOperation
    let timestamp: Date
    let reversed: Bool
    /// Maps destination path -> original source path for undo.
    let originalPaths: [String: String]
}

// MARK: - NLOperationHistory

/// Maintains an undo stack of executed operations.
///
/// Thread-safe via actor isolation. Caps at 20 items — oldest entries are
/// dropped first when the limit is exceeded.
///
/// REQ-3.0-14: Undo support
actor NLOperationHistory {

    private var stack: [NLOperationRecord] = []

    /// Maximum number of records retained. Oldest are dropped first.
    static let maxItems = 20

    /// Record an executed operation so it can be undone later.
    func record(_ operation: NLOperation, reversed: Bool = false, originalPaths: [String: String] = [:]) {
        let record = NLOperationRecord(
            operation: operation,
            timestamp: Date(),
            reversed: reversed,
            originalPaths: originalPaths
        )
        stack.append(record)
        // Drop oldest when over capacity
        if stack.count > Self.maxItems {
            stack.removeFirst(stack.count - Self.maxItems)
        }
    }

    /// Pop the most recent operation record for undo, if any.
    func popLast() -> NLOperationRecord? {
        return stack.popLast()
    }

    /// Whether there is an operation available to undo.
    var canUndo: Bool {
        return !stack.isEmpty
    }

    /// Remove all history.
    func clear() {
        stack.removeAll()
    }
}

// MARK: - NLOperationError

/// Errors thrown during natural-language operation execution.
enum NLOperationError: Error, Equatable, LocalizedError {
    case invalidDestination(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination(let reason):
            return "Invalid destination: \(reason)"
        }
    }
}

// MARK: - NLOperationResult

/// Result of executing an operation through the executor.
struct NLOperationResult: Sendable, Equatable {
    let success: Bool
    let affectedCount: Int
    let status: NLOperationStatus
    /// Per-file errors collected during execution (non-fatal).
    let errors: [String]
}

/// Execution status for an operation.
enum NLOperationStatus: String, Sendable, Equatable {
    case confirmed
    case rejected
    case rejectedDestructive
}

// MARK: - NLOperationExecutor

/// Executes safe file operations with a confirmation callback.
///
/// Only move, copy, and rename operations are allowed. Destructive operations
/// (anything outside the safe set) are rejected immediately without calling
/// the confirmation closure.
///
/// The caller supplies a `confirm` closure (e.g. presenting a UI dialog) that
/// returns `true` to proceed or `false` to cancel.
///
/// After successful execution, each operation is recorded in the history actor
/// so it can be undone via `undoLast()`.
///
/// REQ-3.0-14: Operation execution with confirmation + undo
struct NLOperationExecutor: @unchecked Sendable {

    /// Safe operation types that are permitted for execution.
    static let safeOperationTypes: Set<NLOperationType> = [.move, .copy, .rename]

    let fileManager: any FileManagerProvider
    let history: NLOperationHistory

    init(
        fileManager: any FileManagerProvider = SystemFileManagerProvider(),
        history: NLOperationHistory = NLOperationHistory()
    ) {
        self.fileManager = fileManager
        self.history = history
    }

    /// Execute an operation after user confirmation.
    ///
    /// - Parameters:
    ///   - operation: The operation to execute.
    ///   - confirm: A closure the caller provides to ask the user for confirmation.
    ///     Returns `true` to proceed, `false` to cancel.
    ///   - availableFiles: File paths matching the operation's source pattern,
    ///     typically produced by `generatePreview()`.
    /// - Returns: An `NLOperationResult` with the affected file count and status,
    ///   or `nil` if the operation type is not safe.
    func execute(
        _ operation: NLOperation,
        confirm: () -> Bool,
        availableFiles: [String]
    ) async -> NLOperationResult? {
        // Reject any operation type outside the safe set
        guard Self.safeOperationTypes.contains(operation.type) else {
            return NLOperationResult(
                success: false,
                affectedCount: 0,
                status: .rejectedDestructive,
                errors: []
            )
        }

        // Ask the caller to confirm
        guard confirm() else {
            return NLOperationResult(
                success: false,
                affectedCount: 0,
                status: .rejected,
                errors: []
            )
        }

        // Perform the actual file operations
        var succeededCount = 0
        var errors: [String] = []
        var originalPaths: [String: String] = [:]

        for sourcePath in availableFiles {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let fileName = sourceURL.lastPathComponent
            let destDir: String
            let destFileName: String

            switch operation.type {
            case .move, .copy:
                destDir = operation.destination
                destFileName = fileName
            case .rename:
                // For rename, destination is the new name in the same directory
                destDir = sourceURL.deletingLastPathComponent().path
                destFileName = operation.destination
            }

            // Validate destination path stays within expected directories
            let resolvedDest = (destDir as NSString).standardizingPath
            guard !resolvedDest.contains("..") else {
                errors.append("\(sourcePath): Path traversal not allowed")
                continue
            }
            guard resolvedDest.hasPrefix("/Users/")
                || resolvedDest.hasPrefix("/Volumes")
                || resolvedDest.hasPrefix("/tmp") else {
                errors.append("\(sourcePath): Destination must be within /Users, /Volumes, or /tmp")
                continue
            }

            let destPath = destDir.hasSuffix("/")
                ? destDir + destFileName
                : destDir + "/" + destFileName
            let destURL = URL(fileURLWithPath: destPath)

            do {
                // Create destination directory if needed (move/copy)
                if operation.type != .rename {
                    let destDirURL = URL(fileURLWithPath: destDir)
                    if !fileManager.fileExists(atPath: destDir) {
                        try fileManager.createDirectory(at: destDirURL, withIntermediateDirectories: true)
                    }
                }

                switch operation.type {
                case .move, .rename:
                    try fileManager.moveItem(at: sourceURL, to: destURL)
                case .copy:
                    try fileManager.copyItem(at: sourceURL, to: destURL)
                }

                originalPaths[destPath] = sourcePath
                succeededCount += 1
            } catch {
                errors.append("\(sourcePath): \(error.localizedDescription)")
            }
        }

        let success = errors.isEmpty

        // Record in history for undo (only if something succeeded)
        if succeededCount > 0 {
            await history.record(operation, originalPaths: originalPaths)
        }

        return NLOperationResult(
            success: success,
            affectedCount: succeededCount,
            status: .confirmed,
            errors: errors
        )
    }

    /// Undo the most recently executed operation, if any.
    ///
    /// - Move/rename: moves the file back to its original location.
    /// - Copy: removes the copied file from the destination.
    /// - Returns: the undone `NLOperationRecord`, or `nil` if nothing to undo.
    func undoLast() async -> NLOperationRecord? {
        guard let record = await history.popLast() else { return nil }

        for (destPath, originalPath) in record.originalPaths {
            let destURL = URL(fileURLWithPath: destPath)
            let originalURL = URL(fileURLWithPath: originalPath)

            do {
                switch record.operation.type {
                case .move, .rename:
                    // Move back to original location
                    try fileManager.moveItem(at: destURL, to: originalURL)
                case .copy:
                    // Remove the copy; original was never moved
                    try fileManager.removeItem(at: destURL)
                }
            } catch {
                // Undo failures are best-effort; we still return the record
                // so the caller knows what was attempted.
                break
            }
        }

        return record
    }
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
