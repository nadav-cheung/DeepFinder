// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

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
public struct FullSubstringMap {

    /// Default maximum filename length for substring indexing.
    public static let defaultMaxNameLength = 32

    /// Maximum filename length (in characters) that this map will index.
    /// Configurable per instance to control memory usage.
    public let maxNameLength: Int

    /// Maps lowercase substring -> set of FileRecord IDs containing that substring.
    private var index: [String: Set<UInt32>] = [:]

    public init(maxNameLength: Int = defaultMaxNameLength) {
        self.maxNameLength = max(maxNameLength, 0)
    }

    /// Number of unique filename entries currently stored.
    private var _count: Int = 0

    /// Number of unique filenames inserted (and not yet removed).
    public var count: Int { _count }

    /// Whether the map is empty.
    public var isEmpty: Bool { _count == 0 }

    /// Insert all substrings of `name` and associate them with `id`.
    /// Names longer than `maxNameLength` characters are silently skipped.
    /// Re-inserting the same `id` with a different name does NOT remove the old
    /// substrings — callers must `remove` first if updating.
    ///
    /// - Note: Input is expected to be pre-normalized by InMemoryIndex; the
    ///   NFC normalization here is defensive/idempotent.
    mutating func insert(name: String, id: UInt32) {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard normalized.count <= maxNameLength else { return }

        let lowered = normalized.lowercased()

        // Early-return if this (name, id) pair is already indexed — avoids O(n^2) re-work
        if index[lowered]?.contains(id) == true {
            return
        }

        for startIdx in 0..<lowered.count {
            let start = lowered.index(lowered.startIndex, offsetBy: startIdx)
            for endIdx in (startIdx + 1)...lowered.count {
                let end = lowered.index(lowered.startIndex, offsetBy: endIdx)
                let substring = String(lowered[start..<end])
                index[substring, default: []].insert(id)
            }
        }
        _count += 1
    }

    /// Look up all FileRecord IDs whose filename contains `substring`.
    /// Returns an empty array if no matches.
    /// - Precondition: `substring` must not be empty (use `InMemoryIndex.allRecords()` instead).
    public func search(substring: String) -> [UInt32] {
        precondition(!substring.isEmpty, "FullSubstringMap.search requires a non-empty substring")
        let key = substring.precomposedStringWithCanonicalMapping.lowercased()
        guard let ids = index[key] else { return [] }
        return Array(ids)
    }

    /// Remove `id` from all substring entries generated from `name`.
    /// No-op if the name/id combination was never inserted.
    mutating func remove(name: String, id: UInt32) {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard normalized.count <= maxNameLength else { return }

        let lowered = normalized.lowercased()

        var wasPresent = false
        for startIdx in 0..<lowered.count {
            let start = lowered.index(lowered.startIndex, offsetBy: startIdx)
            for endIdx in (startIdx + 1)...lowered.count {
                let end = lowered.index(lowered.startIndex, offsetBy: endIdx)
                let substring = String(lowered[start..<end])
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
