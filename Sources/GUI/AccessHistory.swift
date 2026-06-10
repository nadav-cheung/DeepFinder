import Foundation

// MARK: - AccessRecord

/// Tracks how often and when a file was opened from search results.
///
/// Used by ``AccessHistoryStore`` to compute a weighted ranking that blends
/// frequency (how many times opened) with recency (when last opened).
struct AccessRecord: Codable, Equatable {
    /// Absolute file path.
    let filePath: String
    /// Number of times this file was opened from DeepFinder.
    var openCount: Int
    /// The most recent time this file was opened.
    var lastOpened: Date
}

// MARK: - AccessHistoryStore

/// Tracks file-open frequency for boosting frequently-accessed results.
///
/// Persists up to ``maxEntries`` records in a JSON file under the DeepFinder cache
/// directory. When the limit is exceeded, the least-recently-used / lowest-count
/// entries are evicted first.
///
/// Ranking formula: `openCount * 0.4 + recencyScore * 0.6`
/// where `recencyScore` is normalized to `[0, 1]` based on the newest entry.
@Observable
final class AccessHistoryStore {

    // MARK: - Constants

    /// Maximum number of access records retained.
    static let maxEntries = 1000

    /// File name for the persisted history.
    private static let fileName = "access-history.json"

    /// Weight for open-count in the ranking formula.
    private static let countWeight = 0.4

    /// Weight for recency in the ranking formula.
    private static let recencyWeight = 0.6

    // MARK: - State

    /// All access records, keyed by file path for O(1) lookup.
    private var recordsByPath: [String: AccessRecord] = [:]

    /// All records as an array, derived from ``recordsByPath``.
    private(set) var allRecords: [AccessRecord] = []

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
    init() {
        self.cacheDir = NSString(string: Product.cacheDir).expandingTildeInPath
        loadFromDisk()
    }

    // MARK: - Public API

    /// Records access to a file path, incrementing the count if it already exists.
    ///
    /// After recording, if the record count exceeds ``maxEntries``, the least-valued
    /// entries (by weighted score) are evicted. Changes are persisted immediately.
    func recordAccess(_ path: String) {
        let now = Date()

        if var existing = recordsByPath[path] {
            existing.openCount += 1
            existing.lastOpened = now
            recordsByPath[path] = existing
        } else {
            let record = AccessRecord(filePath: path, openCount: 1, lastOpened: now)
            recordsByPath[path] = record
        }

        evictIfNeeded()
        rebuildAllRecords()

        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    /// Returns file paths ranked by the weighted formula:
    /// `openCount * 0.4 + recencyScore * 0.6`.
    ///
    /// Recency is normalized relative to the most recent access timestamp
    /// across all records. Paths with no records return unsorted.
    func sortedPaths() -> [String] {
        guard !allRecords.isEmpty else { return [] }

        let maxOpenCount = allRecords.map(\.openCount).max() ?? 1
        let newestDate = allRecords.map(\.lastOpened).max() ?? Date()
        let oldestDate = allRecords.map(\.lastOpened).min() ?? Date()
        let dateRange = newestDate.timeIntervalSince(oldestDate)

        let sorted = allRecords.sorted { a, b in
            let scoreA = weightedScore(a, maxOpenCount: maxOpenCount, newestDate: newestDate, dateRange: dateRange)
            let scoreB = weightedScore(b, maxOpenCount: maxOpenCount, newestDate: newestDate, dateRange: dateRange)
            return scoreA > scoreB
        }

        return sorted.map(\.filePath)
    }

    // MARK: - Private - Scoring

    /// Computes the weighted score for a single record.
    ///
    /// - Parameters:
    ///   - record: The access record to score.
    ///   - maxOpenCount: The highest open count across all records (for normalization).
    ///   - newestDate: The most recent last-opened date (for recency normalization).
    ///   - dateRange: The time interval between newest and oldest dates.
    /// - Returns: A score in `[0, 1]` where higher is more relevant.
    private func weightedScore(
        _ record: AccessRecord,
        maxOpenCount: Int,
        newestDate: Date,
        dateRange: TimeInterval
    ) -> Double {
        let recencyScore: Double
        if dateRange > 0 {
            recencyScore = record.lastOpened.timeIntervalSince(newestDate) / dateRange + 1.0
        } else {
            recencyScore = 1.0
        }

        return Double(record.openCount) * Self.countWeight + recencyScore * Self.recencyWeight
    }

    // MARK: - Private - Eviction

    /// Evicts the lowest-ranked entries when the store exceeds ``maxEntries``.
    ///
    /// Eviction removes entries with the lowest combined score, keeping the
    /// most frequently-accessed and most-recent entries.
    private func evictIfNeeded() {
        guard recordsByPath.count > Self.maxEntries else { return }

        let maxOpenCount = recordsByPath.values.map(\.openCount).max() ?? 1
        let newestDate = recordsByPath.values.map(\.lastOpened).max() ?? Date()
        let oldestDate = recordsByPath.values.map(\.lastOpened).min() ?? Date()
        let dateRange = newestDate.timeIntervalSince(oldestDate)

        let sorted = recordsByPath.values.sorted { a, b in
            let scoreA = weightedScore(a, maxOpenCount: maxOpenCount, newestDate: newestDate, dateRange: dateRange)
            let scoreB = weightedScore(b, maxOpenCount: maxOpenCount, newestDate: newestDate, dateRange: dateRange)
            return scoreA > scoreB
        }

        // Keep only the top maxEntries entries.
        let toRemove = sorted.dropFirst(Self.maxEntries)
        for record in toRemove {
            recordsByPath.removeValue(forKey: record.filePath)
        }
    }

    // MARK: - Private - Derived State

    private func rebuildAllRecords() {
        allRecords = Array(recordsByPath.values)
    }

    // MARK: - Private - Persistence

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let records = try JSONDecoder().decode([AccessRecord].self, from: data)
            for record in records {
                recordsByPath[record.filePath] = record
            }
            rebuildAllRecords()
        } catch {
            // Corrupt or unreadable file — start fresh.
            recordsByPath = [:]
            allRecords = []
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
            let data = try JSONEncoder().encode(allRecords)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silent failure — access history is non-critical.
        }
    }
}
