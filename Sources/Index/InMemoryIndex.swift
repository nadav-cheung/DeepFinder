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
actor InMemoryIndex {

    // MARK: - Internal Storage

    /// ID-to-FileRecord lookup.
    private var records: [UInt32: FileRecord] = [:]

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

    // MARK: - Properties

    /// Number of indexed files.
    var count: Int { records.count }

    /// Whether the index is empty.
    var isEmpty: Bool { records.isEmpty }

    // MARK: - Insert

    /// Insert a pre-built FileRecord into all index structures.
    func insert(_ record: FileRecord) {
        let id = record.id
        let name = record.name

        // Store the record
        records[id] = record

        // Insert into Trie — key is NFC-normalized, lowercased unicode scalars
        let normalizedLower = name.precomposedStringWithCanonicalMapping.lowercased()
        let scalars = Array(normalizedLower.unicodeScalars)
        if !scalars.isEmpty {
            let existing = trie.search(prefix: scalars).first ?? []
            var updated = existing
            updated.insert(id)
            trie.insert(scalars, value: updated)
        }

        // Insert into FullSubstringMap (silently skips names > 64 chars)
        substringMap.insert(name: name, id: id)

        // Insert into TrigramIndex (handles all names, but primarily useful > 64 chars)
        if name.count > FullSubstringMap.maxNameLength {
            trigramIndex.insert(name: name, id: id)
        }

        // Insert into PinyinIndex (silently skips non-Chinese names)
        pinyinIndex.insert(name: name, id: id)
    }

    /// Convenience: insert by name and path, creating a FileRecord with auto-ID.
    func insert(
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
    func remove(id: UInt32) {
        guard let record = records.removeValue(forKey: id) else { return }
        let name = record.name

        // Remove from Trie
        let normalizedLower = name.precomposedStringWithCanonicalMapping.lowercased()
        let scalars = Array(normalizedLower.unicodeScalars)
        if !scalars.isEmpty {
            if var set = trie.search(prefix: scalars).first {
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

    // MARK: - Search

    /// Unified search across all index structures. Returns deduplicated, sorted results.
    func search(query: String) -> [FileRecord] {
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
    func search(query: String, limit: Int) -> [FileRecord] {
        let all = search(query: query)
        return Array(all.prefix(limit))
    }

    /// Return all indexed records. Useful for operations that need the full
    /// dataset (e.g. autocomplete with empty prefix).
    func allRecords() -> [FileRecord] {
        Array(records.values)
    }
}
