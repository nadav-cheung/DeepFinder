// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # Index Module — Everything-style architecture
///
/// Core data structures adapted from Voidtools Everything's proven design:
/// - Sorted filename array + binary search for prefix matching (replaces Trie)
/// - TrigramIndex for substring matching (replaces FullSubstringMap)
/// - Compact [UInt32] posting lists (no Set overhead)
///
/// ## Components
/// - ``FileRecord`` -- immutable record representing a single file or directory
/// - ``InMemoryIndex`` -- actor-isolated composite index
/// - ``TrigramIndex`` -- trigram posting lists for substring search
/// - ``ProductConfig`` -- compile-time product name, paths, and version constants
///
/// ## Search Strategy (Everything-style)
/// 1. Normalize query (NFC + lowercase)
/// 2. Binary search sortedNames for prefix matches
/// 3. TrigramIndex for substring matches
/// 4. Merge all result IDs, deduplicate
/// 5. Look up FileRecords, return sorted by ID
///
/// ## Thread Safety
/// All index structures are value types (structs). ``InMemoryIndex`` is an actor,
/// so all mutations are serialized through actor isolation. No internal locking needed.
///
/// ## Unicode
/// All filenames are NFC-normalized on ingestion via `precomposedStringWithCanonicalMapping`.
/// Queries are normalized the same way for consistent matching.
import Foundation

// MARK: - NameEntry

/// A single entry in the sorted filename array. Comparable by normalized name
/// for binary search prefix matching (Everything-style).
public struct NameEntry: Comparable, Sendable {
    public let normalizedName: String   // lowercased, NFC-normalized
    public let recordID: UInt32

    public static func < (lhs: NameEntry, rhs: NameEntry) -> Bool {
        lhs.normalizedName < rhs.normalizedName
    }
    public static func == (lhs: NameEntry, rhs: NameEntry) -> Bool {
        lhs.normalizedName == rhs.normalizedName
    }
}

// MARK: - InMemoryIndex

/// The single entry point for all indexing and searching operations.
///
/// Architecture follows Voidtools Everything's proven design:
/// - One sorted array of filenames for prefix search (binary search)
/// - One trigram index for substring search
/// - Compact sorted [UInt32] posting lists throughout
///
/// Memory target: ~300MB for 200K files (vs ~3.5GB with Trie + FullSubstringMap).
public actor InMemoryIndex {

    // MARK: - Internal Storage

    /// ID-to-FileRecord lookup.
    private var records: [UInt32: FileRecord] = [:]

    /// Path-to-ID lookup for O(1) path-based removal.
    private var pathToID: [String: UInt32] = [:]

    /// Auto-incrementing ID counter.
    private var nextID: UInt32 = 1

    /// Sorted filename array for prefix search via binary search.
    /// Everything-style: replaces the Trie entirely.
    private var sortedNames: [NameEntry] = []

    /// Trigram index for substring matching (all names).
    private var trigramIndex = TrigramIndex()

    /// Whether batch loading is in progress (avoids O(n²) insert cost).
    private var isBatchLoading = false

    // MARK: - Init

    public init() {}

    // MARK: - Properties

    /// Number of indexed files.
    public var count: Int { records.count }

    /// Whether the index is empty.
    public var isEmpty: Bool { records.isEmpty }

    // MARK: - Insert

    /// Insert a pre-built FileRecord into all index structures.
    /// If a record with the same ID already exists, the old record is removed
    /// from all sub-indices before the new one is inserted (upsert semantics).
    public func insert(_ record: FileRecord) {
        let id = record.id

        // Keep the auto-ID counter above any explicitly-supplied ID
        if id >= nextID {
            nextID = id &+ 1
        }

        let name = record.name

        // B3: path-based upsert
        if let existingID = pathToID[record.path], existingID != id {
            if let oldRecord = records[existingID] {
                _removeFromIndices(oldRecord)
            }
            records.removeValue(forKey: existingID)
        }

        // If overwriting, remove old entries first
        if let oldRecord = records[id] {
            _removeFromIndices(oldRecord)
            pathToID.removeValue(forKey: oldRecord.path)
        }

        // Store the record
        records[id] = record
        pathToID[record.path] = id

        // Insert into sortedNames
        let normalizedLower = name.precomposedStringWithCanonicalMapping.lowercased()
        let entry = NameEntry(normalizedName: normalizedLower, recordID: id)

        if isBatchLoading {
            // Batch mode: just append, sort at end
            sortedNames.append(entry)
        } else {
            // Live mode: binary search insert (O(n) shift, fine for single updates)
            _sortedInsertName(entry)
        }

        // Insert into TrigramIndex for substring search
        trigramIndex.insert(name: name, id: id)
    }

    /// Enable batch loading mode. Calls to insert() will append without sorting.
    /// Call finalizeBatchLoad() after all records are inserted.
    public func beginBatchLoad() {
        isBatchLoading = true
    }

    /// Sort the names array and exit batch loading mode.
    /// Must be called after beginBatchLoad() + insertBatch().
    public func finalizeBatchLoad() {
        sortedNames.sort()
        isBatchLoading = false
    }

    /// Batch-insert multiple records. Uses batch mode internally for O(N log N) sort.
    public func insertBatch(_ newRecords: [FileRecord]) {
        isBatchLoading = true
        for record in newRecords {
            insert(record)
        }
        finalizeBatchLoad()
    }

    /// Batch-remove records by ID.
    public func deleteBatch(_ ids: [UInt32]) {
        for id in ids {
            remove(id: id)
        }
    }

    /// Convenience: insert by name and path, creating a FileRecord with auto-ID.
    public func insert(
        name: String,
        path: String,
        parentPath: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        extension ext: String? = nil
    ) {
        let id = nextID
        nextID += 1

        let record = FileRecord(
            id: id,
            name: name.precomposedStringWithCanonicalMapping,
            originalName: name,
            path: path,
            parentPath: parentPath,
            isDirectory: isDirectory,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: ext
        )
        insert(record)
    }

    // MARK: - Remove

    /// Remove a file by ID from all index structures.
    public func remove(id: UInt32) {
        guard let record = records.removeValue(forKey: id) else { return }
        pathToID.removeValue(forKey: record.path)
        _removeFromIndices(record)
    }

    /// Remove a file by its absolute path. O(1).
    public func removeByPath(_ path: String) -> Bool {
        guard let id = pathToID[path] else { return false }
        remove(id: id)
        return true
    }

    /// Remove a record's entries from sortedNames and trigramIndex.
    private func _removeFromIndices(_ record: FileRecord) {
        let id = record.id
        let name = record.name
        let normalizedLower = name.precomposedStringWithCanonicalMapping.lowercased()

        // Remove from sortedNames — binary search for exact match
        _sortedRemoveName(normalizedName: normalizedLower, recordID: id)

        // Remove from TrigramIndex
        trigramIndex.remove(name: name, id: id)
    }

    // MARK: - Volume Operations

    /// Remove all records whose path starts with the given volume path prefix.
    public func removeRecordsForVolume(volumePath: String) -> [UInt32] {
        let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        let exactMatch = volumePath

        var removedIDs: [UInt32] = []
        for (id, record) in records {
            if record.path == exactMatch || record.path.hasPrefix(prefix) {
                removedIDs.append(id)
            }
        }

        for id in removedIDs {
            remove(id: id)
        }

        return removedIDs
    }

    // MARK: - Search

    /// Prefix search via binary search on sortedNames array (Everything-style).
    /// Returns sorted record IDs matching the prefix.
    private func _prefixSearch(_ prefix: String) -> [UInt32] {
        guard !prefix.isEmpty, !sortedNames.isEmpty else { return [] }

        // Binary search for first entry >= prefix
        var lo = 0, hi = sortedNames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedNames[mid].normalizedName < prefix {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Scan forward collecting matches
        var result: [UInt32] = []
        var i = lo
        while i < sortedNames.count, sortedNames[i].normalizedName.hasPrefix(prefix) {
            result.append(sortedNames[i].recordID)
            i += 1
        }
        return result
    }

    /// Unified search across all index structures.
    public func search(query: String) -> [FileRecord] {
        let normalized = query.precomposedStringWithCanonicalMapping
        let lowered = normalized.lowercased()

        guard !lowered.isEmpty else { return [] }

        // 1. Prefix matches from sortedNames (binary search)
        let prefixIDs = _prefixSearch(lowered)

        // 2. Substring matches from TrigramIndex
        let substringIDs = trigramIndex.search(substring: lowered)

        // 3. Merge both sources
        let matchedIDs = mergeSorted(prefixIDs, substringIDs)
        return matchedIDs.compactMap { id in records[id] }.sorted { $0.id < $1.id }
    }

    /// Search with a limit on the number of results.
    public func search(query: String, limit: Int) -> [FileRecord] {
        let normalized = query.precomposedStringWithCanonicalMapping
        let lowered = normalized.lowercased()
        guard !lowered.isEmpty else { return [] }

        // Collect from both indices, short-circuit at limit
        var matchedIDs = _prefixSearch(lowered)
        if matchedIDs.count >= limit {
            return matchedIDs.prefix(limit).compactMap { records[$0] }
        }

        matchedIDs = mergeSorted(matchedIDs, trigramIndex.search(substring: lowered))
        return matchedIDs.prefix(limit).compactMap { records[$0] }
    }

    /// Return all indexed records.
    public func allRecords() -> [FileRecord] {
        Array(records.values)
    }

    // MARK: - Snapshot

    /// Capture an immutable snapshot of the entire index state.
    public func snapshot() -> IndexSnapshot {
        IndexSnapshot(
            records: records,
            pathToID: pathToID,
            sortedNames: sortedNames,
            trigramIndex: trigramIndex
        )
    }

    // MARK: - Private: Sorted Array Operations

    /// Binary search insert into sortedNames. O(log N) find + O(N) shift.
    private func _sortedInsertName(_ entry: NameEntry) {
        var lo = 0, hi = sortedNames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedNames[mid] < entry {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        sortedNames.insert(entry, at: lo)
    }

    /// Binary search remove from sortedNames. Finds entry matching both name and ID.
    private func _sortedRemoveName(normalizedName: String, recordID: UInt32) {
        // Binary search for the first entry with this name
        var lo = 0, hi = sortedNames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedNames[mid].normalizedName < normalizedName {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // Scan forward to find the entry with matching ID
        var i = lo
        while i < sortedNames.count, sortedNames[i].normalizedName == normalizedName {
            if sortedNames[i].recordID == recordID {
                sortedNames.remove(at: i)
                return
            }
            i += 1
        }
    }
}

// MARK: - IndexSnapshot

/// Immutable snapshot of the in-memory index state.
///
/// Captured atomically via ``InMemoryIndex/snapshot()``. Because all
/// sub-indices are value types (structs), the snapshot is a fully independent
/// copy — concurrent mutations to the live index do not affect it.
///
/// `@unchecked Sendable` is safe because the snapshot is captured atomically
/// inside ``InMemoryIndex/snapshot()`` (a single actor hop). All sub-indices
/// are value types — once copied out of the actor, they are effectively immutable.
public struct IndexSnapshot: @unchecked Sendable {

    /// Records by ID.
    public let records: [UInt32: FileRecord]

    /// Path-to-ID lookup.
    public let pathToID: [String: UInt32]

    /// Sorted filename array for prefix search (Everything-style).
    public let sortedNames: [NameEntry]

    /// Trigram index for substring search.
    public let trigramIndex: TrigramIndex

    /// Number of indexed files in this snapshot.
    public var count: Int { records.count }

    /// Whether the snapshot is empty.
    public var isEmpty: Bool { records.isEmpty }

    /// Look up a record by its path.
    public func record(atPath path: String) -> FileRecord? {
        guard let id = pathToID[path] else { return nil }
        return records[id]
    }

    /// Return all indexed records.
    public func allRecords() -> [FileRecord] {
        Array(records.values)
    }
}
