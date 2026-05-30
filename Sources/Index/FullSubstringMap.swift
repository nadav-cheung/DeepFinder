/// Maps ALL substrings of a filename to sets of `FileRecord.ID` values.
///
/// For filenames <= 64 characters, this provides O(1) substring lookup by
/// pre-computing every possible substring. Names longer than 64 characters
/// are silently skipped (TrigramIndex handles those).
///
/// All keys are stored lowercased for case-insensitive search. Input names
/// should be NFC-normalized before insertion (consistent with FileRecord).
///
/// Thread safety: This is a value type (struct). When used inside an actor
/// (e.g. `InMemoryIndex`), no internal synchronization is needed.
struct FullSubstringMap {

    /// Maximum filename length (in characters) that this map will index.
    /// Longer names are handled by TrigramIndex.
    static let maxNameLength = 64

    /// Maps lowercase substring -> set of FileRecord IDs containing that substring.
    private var index: [String: Set<UInt32>] = [:]

    /// Number of unique filename entries currently stored.
    private var _count: Int = 0

    /// Number of unique filenames inserted (and not yet removed).
    var count: Int { _count }

    /// Whether the map is empty.
    var isEmpty: Bool { _count == 0 }

    /// Insert all substrings of `name` and associate them with `id`.
    /// Names longer than `maxNameLength` characters are silently skipped.
    /// Re-inserting the same `id` with a different name does NOT remove the old
    /// substrings — callers must `remove` first if updating.
    mutating func insert(name: String, id: UInt32) {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard normalized.count <= Self.maxNameLength else { return }

        let lowered = normalized.lowercased()
        let chars = Array(lowered)

        // Track whether this is a new entry to avoid double-counting
        let isNew = index[lowered, default: []].insert(id).inserted

        for start in 0..<chars.count {
            for end in (start + 1)...chars.count {
                let substring = String(chars[start..<end])
                index[substring, default: []].insert(id)
            }
        }
        if isNew {
            _count += 1
        }
    }

    /// Look up all FileRecord IDs whose filename contains `substring`.
    /// Returns an empty array if no matches. Empty query returns all IDs.
    func search(substring: String) -> [UInt32] {
        let key = substring.precomposedStringWithCanonicalMapping.lowercased()
        if key.isEmpty {
            // Collect all unique IDs across all substrings
            var all = Set<UInt32>()
            for ids in index.values {
                all.formUnion(ids)
            }
            return Array(all)
        }
        guard let ids = index[key] else { return [] }
        return Array(ids)
    }

    /// Remove `id` from all substring entries generated from `name`.
    /// No-op if the name/id combination was never inserted.
    mutating func remove(name: String, id: UInt32) {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard normalized.count <= Self.maxNameLength else { return }

        let lowered = normalized.lowercased()
        let chars = Array(lowered)

        var wasPresent = false
        for start in 0..<chars.count {
            for end in (start + 1)...chars.count {
                let substring = String(chars[start..<end])
                if var ids = index[substring] {
                    if ids.remove(id) != nil {
                        wasPresent = true
                    }
                    if ids.isEmpty {
                        index.removeValue(forKey: substring)
                    } else {
                        index[substring] = ids
                    }
                }
            }
        }
        if wasPresent {
            _count -= 1
        }
    }
}
