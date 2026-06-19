// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # Index Module
///
/// Core data structures for in-memory file indexing, optimized for sub-millisecond
/// search on Apple Silicon M4+ with unified memory.
///
/// ## Components
/// - ``FileRecord`` -- immutable record representing a single file or directory
/// - ``InMemoryIndex`` -- actor-isolated composite index composing all structures below
/// - ``Trie`` -- generic prefix tree for O(k) prefix lookup on Unicode scalars
/// - ``FullSubstringMap`` -- precomputed all-substrings map for O(1) lookup (names <= 64 chars)
/// - ``TrigramIndex`` -- trigram posting lists for long filenames (> 64 chars)
/// - ``PinyinIndex`` -- Chinese character to pinyin mapping for CJK filename search
/// - ``ProductConfig`` -- compile-time product name, paths, and version constants
///
/// ## Search Strategy
/// 1. Normalize query (NFC + lowercase)
/// 2. Query Trie for prefix matches
/// 3. Query FullSubstringMap for substring matches (names <= 64 chars)
/// 4. Query TrigramIndex for long-name matches (names > 64 chars)
/// 5. Query PinyinIndex for Chinese pinyin matches
/// 6. Merge all result IDs, deduplicate
/// 7. Look up FileRecords, return sorted by ID
///
/// ## Thread Safety
/// All index structures are value types (structs). ``InMemoryIndex`` is an actor,
/// so all mutations are serialized through actor isolation. No internal locking needed.
///
/// ## Unicode
/// All filenames are NFC-normalized on ingestion via `precomposedStringWithCanonicalMapping`.
/// Queries are normalized the same way for consistent matching.
import Foundation

/// The single entry point for all indexing and searching operations.
///
/// An actor that composes all index structures (Trie, FullSubstringMap,
/// TrigramIndex, PinyinIndex) and a FileRecord store. All read/write
/// access is via actor isolation — no internal synchronization needed
/// for the value-type index structures.
///
/// Search strategy:
/// 1. Normalize query (NFC + lowercase)
/// 2. Query Trie for prefix matches
/// 3. Query FullSubstringMap for substring matches (names <= 64 chars)
/// 4. Query TrigramIndex for long-name matches (names > 64 chars)
/// 5. Query PinyinIndex for pinyin matches
/// 6. Merge all result IDs, deduplicate
/// 7. Look up FileRecords, return sorted by ID
public actor InMemoryIndex {

    // MARK: - Internal Storage

    /// ID-to-FileRecord lookup.
    private var records: [UInt32: FileRecord] = [:]

    /// Path-to-ID lookup for O(1) path-based removal.
    private var pathToID: [String: UInt32] = [:]

    /// Auto-incrementing ID counter.
    private var nextID: UInt32 = 1

    /// Trie for prefix matching. Stores sets of IDs at prefix-terminating nodes.
    /// Keys are NFC-normalized, lowercased Unicode scalar arrays of the filename.
    private var trie = Trie<UnicodeScalar, Set<UInt32>>()

    /// Full substring map for filenames <= 64 characters.
    private var substringMap = FullSubstringMap()

    /// Trigram index for filenames > 64 characters.
    private var trigramIndex = TrigramIndex()

    /// Pinyin index for Chinese filename search.
    private var pinyinIndex = PinyinIndex()

    // MARK: - Init

    /// Create an empty index.
    /// - Parameter maxSubstringLength: Max filename length for FullSubstringMap.
    ///   Shorter = less memory. Default 24 (~1GB for 200K files).
    public init(maxSubstringLength: Int = Constants.Scan.defaultSubstringMaxLength) {
        self.maxSubstringLength = maxSubstringLength
        self.substringMap = FullSubstringMap(maxNameLength: maxSubstringLength)
    }

    /// Max filename length for FullSubstringMap. Names longer than this use TrigramIndex.
    private let maxSubstringLength: Int

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

        // Keep the auto-ID counter above any explicitly-supplied ID, so the live
        // FSEvents create path (which allocates via the auto-ID convenience
        // insert) can never reuse an ID already held by a scanned or reloaded
        // record. This makes `nextID` a true high-water mark and the single
        // source of truth for ID allocation — covering both the initial-scan path
        // and the SQLite reload path, which both arrive here with explicit IDs.
        if id >= nextID {
            nextID = id &+ 1
        }

        let name = record.name

        // B3: path-based upsert — when the same path already exists under a
        // different ID (re-scan or FSEvents re-add), remove the old entry to
        // prevent duplicate records piling up for the same file.
        if let existingID = pathToID[record.path], existingID != id {
            if let oldRecord = records[existingID] {
                removeFromSubindices(oldRecord)
            }
            records.removeValue(forKey: existingID)
        }

        // If overwriting, remove old entries from sub-indices first
        if let oldRecord = records[id] {
            removeFromSubindices(oldRecord)
            pathToID.removeValue(forKey: oldRecord.path)
        }

        // Store the record
        records[id] = record
        pathToID[record.path] = id

        // Insert into Trie — key is NFC-normalized, lowercased unicode scalars
        let normalizedLower = name.precomposedStringWithCanonicalMapping.lowercased()
        let scalars = Array(normalizedLower.unicodeScalars)
        if !scalars.isEmpty {
            let existing = trie.get(key: scalars) ?? []
            var updated = existing
            updated.insert(id)
            trie.insert(scalars, value: updated)
        }

        // Insert into FullSubstringMap (silently skips names > 64 chars)
        substringMap.insert(name: name, id: id)

        // Insert into TrigramIndex (handles all names, but primarily useful > 64 chars)
        if name.count > maxSubstringLength {
            trigramIndex.insert(name: name, id: id)
        }

        // Insert into PinyinIndex (silently skips non-Chinese names)
        pinyinIndex.insert(name: name, id: id)
    }

    /// Batch-insert multiple records in a single actor hop.
    /// Much faster than individual inserts during startup reindexing.
    public func insertBatch(_ newRecords: [FileRecord]) {
        for record in newRecords {
            insert(record)
        }
    }

    /// Batch-remove records by ID in a single actor hop — symmetric counterpart
    /// to ``insertBatch(_:)``, used for bulk deletions such as volume-unmount cleanup.
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
        removeFromSubindices(record)
    }

    /// Remove a file by its absolute path. Returns `true` if a record was found and removed.
    ///
    /// O(1) path-based lookup — avoids the costly name-search approach.
    public func removeByPath(_ path: String) -> Bool {
        guard let id = pathToID[path] else { return false }
        remove(id: id)
        return true
    }

    /// Remove a record's entries from all sub-indices (Trie, substringMap,
    /// trigramIndex, pinyinIndex) without removing it from the records dict.
    /// Used by both `remove(id:)` and the upsert path in `insert(_:)`.
    private func removeFromSubindices(_ record: FileRecord) {
        let id = record.id
        let name = record.name

        // Remove from Trie
        let normalizedLower = name.precomposedStringWithCanonicalMapping.lowercased()
        let scalars = Array(normalizedLower.unicodeScalars)
        if !scalars.isEmpty {
            if var set = trie.get(key: scalars) {
                set.remove(id)
                if set.isEmpty {
                    trie.remove(scalars)
                } else {
                    trie.insert(scalars, value: set)
                }
            }
        }

        // Remove from FullSubstringMap
        substringMap.remove(name: name, id: id)

        // Remove from TrigramIndex
        trigramIndex.remove(name: name, id: id)

        // Remove from PinyinIndex
        pinyinIndex.remove(name: name, id: id)
    }

    // MARK: - Volume Operations

    /// Remove all records whose path starts with the given volume path prefix.
    ///
    /// Used when a volume is unmounted to clean up all indexed files on that volume.
    /// Returns the IDs of removed records for downstream persistence cleanup.
    ///
    /// - Parameter volumePath: The mount point path of the volume (e.g. "/Volumes/USB Drive").
    /// - Returns: Array of removed record IDs.
    public func removeRecordsForVolume(volumePath: String) -> [UInt32] {
        let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        // Also match the volume path itself (in case a record has path == volumePath)
        let exactMatch = volumePath

        var removedIDs: [UInt32] = []
        for (id, record) in records {
            if record.path == exactMatch || record.path.hasPrefix(prefix) {
                removedIDs.append(id)
            }
        }

        // Remove each record via the normal remove path (updates all index structures)
        for id in removedIDs {
            remove(id: id)
        }

        return removedIDs
    }

    // MARK: - Search

    /// Unified search across all index structures. Returns deduplicated, sorted results.
    public func search(query: String) -> [FileRecord] {
        let normalized = query.precomposedStringWithCanonicalMapping
        let lowered = normalized.lowercased()

        // Empty query returns empty (no "return everything" behavior)
        guard !lowered.isEmpty else { return [] }

        let scalars = Array(lowered.unicodeScalars)

        // 1. Trie prefix matches
        var matchedIDs = Set<UInt32>()
        if !scalars.isEmpty {
            let trieResults = trie.search(prefix: scalars)
            for set in trieResults {
                matchedIDs.formUnion(set)
            }
        }

        // 2. FullSubstringMap matches
        let substringResults = substringMap.search(substring: lowered)
        matchedIDs.formUnion(substringResults)

        // 3. TrigramIndex matches (for long names)
        let trigramResults = trigramIndex.search(substring: lowered)
        matchedIDs.formUnion(trigramResults)

        // 4. PinyinIndex matches
        let pinyinResults = pinyinIndex.search(pinyin: lowered)
        matchedIDs.formUnion(pinyinResults)

        // 5. Look up records, sort by ID for deterministic ordering
        return matchedIDs.compactMap { id in records[id] }.sorted { $0.id < $1.id }
    }

    /// Search with a limit on the number of results.
    /// Short-circuits after finding `limit` results to avoid full materialization.
    public func search(query: String, limit: Int) -> [FileRecord] {
        let normalized = query.precomposedStringWithCanonicalMapping
        let lowered = normalized.lowercased()
        guard !lowered.isEmpty else { return [] }

        let scalars = Array(lowered.unicodeScalars)

        // Collect matched IDs from all sub-indices
        var matchedIDs = Set<UInt32>()
        if !scalars.isEmpty {
            let trieResults = trie.search(prefix: scalars)
            for set in trieResults {
                matchedIDs.formUnion(set)
                if matchedIDs.count >= limit { break }
            }
        }

        if matchedIDs.count < limit {
            let substringResults = substringMap.search(substring: lowered)
            matchedIDs.formUnion(substringResults)
        }
        if matchedIDs.count < limit {
            let trigramResults = trigramIndex.search(substring: lowered)
            matchedIDs.formUnion(trigramResults)
        }
        if matchedIDs.count < limit {
            let pinyinResults = pinyinIndex.search(pinyin: lowered)
            matchedIDs.formUnion(pinyinResults)
        }

        // Sort the (cheap) UInt32 IDs and select only `limit` *before* fetching the
        // (larger) FileRecord values. A broad prefix match can collect many IDs; this
        // avoids materializing a FileRecord for every match just to discard most of
        // them. Output is identical to fetch-all-then-sort-then-truncate because IDs
        // are unique and present in `records`.
        return matchedIDs
            .sorted()
            .prefix(limit)
            .compactMap { id in records[id] }
    }

    /// Return all indexed records. Useful for operations that need the full
    /// dataset (e.g. autocomplete with empty prefix).
    public func allRecords() -> [FileRecord] {
        Array(records.values)
    }

    // MARK: - Snapshot

    /// Capture an immutable snapshot of the entire index state.
    ///
    /// The snapshot is a value-type copy of all internal data structures.
    /// Because the sub-indices (Trie, FullSubstringMap, TrigramIndex, PinyinIndex)
    /// are value types, the snapshot is fully independent — mutations to the
    /// live index after `snapshot()` returns do not affect the snapshot.
    ///
    /// Use this when you need a consistent view of the index across multiple
    /// queries (e.g. SearchCoordinator batching) without holding the actor lock.
    ///
    /// - Returns: An ``IndexSnapshot`` capturing all records and index structures.
    public func snapshot() -> IndexSnapshot {
        IndexSnapshot(
            records: records,
            pathToID: pathToID,
            trie: trie,
            substringMap: substringMap,
            trigramIndex: trigramIndex,
            pinyinIndex: pinyinIndex
        )
    }
}

/// Immutable snapshot of the in-memory index state.
///
/// Captured atomically via ``InMemoryIndex/snapshot()``. Because all
/// sub-indices are value types (structs), the snapshot is a fully independent
/// copy — concurrent mutations to the live index do not affect it.
///
/// Provides the same search API as ``InMemoryIndex`` for convenience,
/// but runs outside actor isolation (no synchronization overhead).
///
/// `@unchecked Sendable` is safe because the snapshot is captured atomically
/// inside ``InMemoryIndex/snapshot()`` (a single actor hop). All sub-indices
/// are value types — once copied out of the actor, they are effectively immutable.
public struct IndexSnapshot: @unchecked Sendable {

    /// Records by ID.
    public let records: [UInt32: FileRecord]

    /// Path-to-ID lookup.
    public let pathToID: [String: UInt32]

    /// Prefix index.
    public let trie: Trie<UnicodeScalar, Set<UInt32>>

    /// Substring index (names ≤ 64 chars).
    public let substringMap: FullSubstringMap

    /// Trigram index (names > 64 chars).
    public let trigramIndex: TrigramIndex

    /// Pinyin index (CJK filenames).
    public let pinyinIndex: PinyinIndex

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
