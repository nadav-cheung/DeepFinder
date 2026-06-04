/// Trigram-based substring index for filenames too long for FullSubstringMap (>64 chars).
///
/// Breaks filenames into 3-Unicode-scalar trigrams and maps each trigram to a posting
/// list of `FileRecord.ID` values. Query: extract trigrams from the query substring,
/// intersect posting lists to find candidates, then verify each candidate actually
/// contains the substring (preventing false positives from trigram collisions).
///
/// All input is NFC-normalized and lowercased for case-insensitive search.
///
/// For queries shorter than 3 Unicode scalars, falls back to a linear scan of all
/// stored names.
///
/// Thread safety: This is a value type (struct). When used inside an actor
/// (e.g. `InMemoryIndex`), no internal synchronization is needed.
struct TrigramIndex {

    /// Maps a 3-Unicode-scalar trigram (as String) to the set of FileRecord IDs
    /// whose names contain that trigram.
    private var postingLists: [String: Set<UInt32>] = [:]

    /// Stores the NFC-normalized, lowercased name for each FileRecord ID.
    /// Used for short-query fallback and for exact verification.
    private var names: [UInt32: String] = [:]

    /// Number of unique filename entries currently stored.
    private var _count: Int = 0

    var count: Int { _count }

    var isEmpty: Bool { _count == 0 }

    // MARK: - Insert

    /// Insert `name` associated with `id`. Extracts all trigrams from the
    /// NFC-normalized, lowercased name and adds `id` to each trigram's posting list.
    /// Re-inserting an existing `id` updates the stored name and posting lists.
    mutating func insert(name: String, id: UInt32) {
        let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
        let scalars = Array(normalized.unicodeScalars)
        guard scalars.count >= 3 else {
            // Too short for trigrams — still store the name for short-query fallback
            if names[id] == nil {
                _count += 1
            }
            names[id] = normalized
            return
        }

        // If re-inserting, remove old posting lists first
        if let oldName = names[id] {
            let oldScalars = Array(oldName.unicodeScalars)
            for i in 0..<(oldScalars.count - 2) {
                let trigram = Self.makeTrigram(scalars: oldScalars, at: i)
                if var posting = postingLists[trigram] {
                    posting.remove(id)
                    if posting.isEmpty {
                        postingLists.removeValue(forKey: trigram)
                    } else {
                        postingLists[trigram] = posting
                    }
                }
            }
        } else {
            _count += 1
        }

        names[id] = normalized

        for i in 0..<(scalars.count - 2) {
            let trigram = Self.makeTrigram(scalars: scalars, at: i)
            postingLists[trigram, default: []].insert(id)
        }
    }

    // MARK: - Search

    /// Search for all FileRecord IDs whose filename contains `substring`.
    ///
    /// For queries >= 3 Unicode scalars: extracts trigrams, intersects posting lists,
    /// then verifies each candidate contains the substring exactly.
    /// For queries < 3 Unicode scalars: linear scan of all stored names.
    func search(substring: String) -> [UInt32] {
        let normalized = substring.precomposedStringWithCanonicalMapping.lowercased()
        if normalized.isEmpty {
            return Array(names.keys)
        }

        let scalars = Array(normalized.unicodeScalars)

        // Short query fallback: linear scan
        if scalars.count < 3 {
            return names.compactMap { (id, name) in
                name.contains(normalized) ? id : nil
            }
        }

        // Extract query trigrams
        var candidateIDs: Set<UInt32>? = nil
        for i in 0..<(scalars.count - 2) {
            let trigram = Self.makeTrigram(scalars: scalars, at: i)
            guard let posting = postingLists[trigram] else {
                return [] // A required trigram is missing — no results possible
            }
            if let current = candidateIDs {
                candidateIDs = current.intersection(posting)
            } else {
                candidateIDs = posting
            }
            if candidateIDs!.isEmpty {
                return [] // Early exit: intersection is already empty
            }
        }

        guard let candidates = candidateIDs else { return [] }

        // Exact verification: confirm each candidate actually contains the substring
        return candidates.filter { id in
            guard let name = names[id] else { return false }
            return name.contains(normalized)
        }
    }

    // MARK: - Remove

    /// Remove `id` from all trigram posting lists and the name store.
    /// No-op if the id was never inserted.
    /// - Parameter name: Unused; kept for API symmetry with FullSubstringMap.remove.
    mutating func remove(name _: String, id: UInt32) {
        guard let storedName = names.removeValue(forKey: id) else { return }
        _count -= 1

        let scalars = Array(storedName.unicodeScalars)
        for i in 0..<(scalars.count - 2) {
            let trigram = Self.makeTrigram(scalars: scalars, at: i)
            if var posting = postingLists[trigram] {
                posting.remove(id)
                if posting.isEmpty {
                    postingLists.removeValue(forKey: trigram)
                } else {
                    postingLists[trigram] = posting
                }
            }
        }
    }

    // MARK: - Private

    /// Build a trigram string from 3 consecutive scalars starting at index `i`.
    private static func makeTrigram(scalars: [Unicode.Scalar], at i: Int) -> String {
        String(String.UnicodeScalarView(scalars[i..<(i + 3)]))
    }
}
