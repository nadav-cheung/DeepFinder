import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - SearchHistoryEntry

/// A single query in the search history.
///
/// Deduplication is by query string — re-running the same query
/// updates the timestamp rather than adding a duplicate entry.
public struct SearchHistoryEntry: Codable, Equatable {
    /// The search query text entered by the user.
    public let query: String
    /// When this query was last submitted.
    public var timestamp: Date
}

// MARK: - SearchHistoryStore

/// Persists recent search queries for the search bar's history dropdown.
///
/// Stores up to ``maxEntries`` entries in a JSON file under the DeepFinder cache directory.
/// Re-submitting an existing query moves it to the top by updating its timestamp.
@Observable
public final class SearchHistoryStore {

    // MARK: - Constants

    /// Maximum number of history entries retained.
    public static let maxEntries = 100

    /// File name for the persisted history.
    private static let fileName = "search-history.json"

    // MARK: - State

    /// All history entries, sorted newest first.
    private(set) var entries: [SearchHistoryEntry] = []

    /// Pending save work item, debounced to avoid frequent disk writes.
    private nonisolated var saveWorkItem: DispatchWorkItem?

    // MARK: - Persistence

    /// Expanded cache directory path (``Product/cacheDir`` with `~` resolved).
    private let cacheDir: String

    /// Expanded file URL for the history JSON file.
    private var fileURL: URL {
        URL(fileURLWithPath: cacheDir).appendingPathComponent(Self.fileName)
    }

    // MARK: - Init

    /// Creates the store and loads any existing history from disk.
    /// Call on `@MainActor` since mutations trigger SwiftUI view updates.
    public init() {
        self.cacheDir = NSString(string: Product.cacheDir).expandingTildeInPath
        loadFromDisk()
    }

    // MARK: - Public API

    /// Records a search query, deduplicating by updating the timestamp if it already exists.
    ///
    /// After recording, entries are sorted newest-first and truncated to ``maxEntries``.
    /// The result is persisted to disk immediately.
    public func addEntry(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()

        if let index = entries.firstIndex(where: { $0.query == trimmed }) {
            entries[index].timestamp = now
        } else {
            entries.append(SearchHistoryEntry(query: trimmed, timestamp: now))
        }

        entries.sort { $0.timestamp > $1.timestamp }
        if entries.count > Self.maxEntries {
            entries.removeSubrange(Self.maxEntries...)
        }

        debounceSave()
    }

    /// Returns the most recent history entries, sorted by timestamp descending.
    public func recentEntries(limit: Int = 10) -> [SearchHistoryEntry] {
        Array(entries.prefix(limit))
    }

    /// Removes the entry at the given index.
    public func removeEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        debounceSave()
    }

    /// Removes all history entries and deletes the backing file.
    public func clearAll() {
        entries.removeAll()
        debounceSave()
    }

    // MARK: - Private - Persistence

    /// Debounces disk writes by cancelling any pending save and scheduling a new one after 2 seconds.
    private func debounceSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([SearchHistoryEntry].self, from: data)
        } catch {
            // Corrupt or unreadable file — start fresh rather than crash.
            entries = []
        }
    }

    private func saveToDisk() {
        let fm = FileManager.default

        // Ensure cache directory exists.
        if !fm.fileExists(atPath: cacheDir) {
            do {
                try fm.createDirectory(
                    atPath: cacheDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: Product.privateDirPermissions]
                )
            } catch {
                return
            }
        }

        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silent failure — history is non-critical.
        }
    }
}
