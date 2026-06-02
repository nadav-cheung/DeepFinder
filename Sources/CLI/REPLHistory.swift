import Foundation

// MARK: - REPLHistory

/// Manages command history for the interactive REPL.
///
/// Persists history entries to a file (one entry per line) with:
/// - Consecutive-duplicate suppression
/// - Configurable maximum entry count
/// - Atomic file saves (write to .tmp, then rename)
/// - File permissions restricted to owner-only (0600)
actor REPLHistory {

    // MARK: - Properties

    /// Path to the history file on disk.
    private let filePath: String

    /// Maximum number of entries to keep.
    private let maxEntries: Int

    /// In-memory entry list, oldest-first order.
    private var entries: [String] = []

    // MARK: - Initialization

    /// Create a history manager.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the history file.
    ///   - maxEntries: Maximum entries to retain. Defaults to 1000.
    init(filePath: String, maxEntries: Int = Constants.REPL.maxHistoryEntries) {
        self.filePath = filePath
        self.maxEntries = maxEntries
    }

    // MARK: - Public API

    /// Number of history entries currently held.
    var count: Int {
        entries.count
    }

    /// Add an entry to history.
    ///
    /// Skips empty strings and consecutive duplicates.
    /// Trims to `maxEntries` if exceeded.
    func add(_ entry: String) {
        guard !entry.isEmpty else { return }
        // Skip consecutive duplicate
        if entries.last == entry { return }
        entries.append(entry)
        trim()
    }

    /// Load history from the on-disk file.
    ///
    /// Replaces any in-memory entries. If the file does not exist,
    /// results in an empty history (no error thrown).
    func load() throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            entries = []
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        guard let text = String(data: data, encoding: .utf8) else {
            entries = []
            return
        }
        entries = text
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        trim()
    }

    /// Persist history to the on-disk file.
    ///
    /// Uses atomic save: writes to a `.tmp` file, then renames.
    /// Sets file permissions to 0600 (owner read/write only).
    func save() throws {
        let content = entries.joined(separator: "\n")

        // Ensure parent directory exists
        let parentDir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Write atomically — .atomic handles temp file + rename internally
        guard let data = content.data(using: .utf8) else { return }
        try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)

        // Set permissions to owner-only
        try FileManager.default.setAttributes(
            [.posixPermissions: Product.privateFilePermissions],
            ofItemAtPath: filePath
        )
    }

    /// Return the last `count` entries (or all if fewer than `count`).
    func recent(_ count: Int) -> [String] {
        let start = Swift.max(0, entries.count - count)
        return Array(entries[start...])
    }

    /// Return all entries that start with the given prefix.
    func search(prefix: String) -> [String] {
        entries.filter { $0.hasPrefix(prefix) }
    }

    /// Clear all history entries from memory.
    /// Does not affect the on-disk file until `save()` is called.
    func clear() {
        entries.removeAll()
    }

    // MARK: - Private

    /// Trim entries to `maxEntries`, keeping the most recent.
    private func trim() {
        guard entries.count > maxEntries else { return }
        let dropCount = entries.count - maxEntries
        entries.removeFirst(dropCount)
    }
}
