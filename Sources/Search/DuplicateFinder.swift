import Foundation

/// A group of files that are considered duplicates by some criterion.
struct DuplicateGroup: Sendable {
    /// The grouping key: file name, size string, hash digest, or "empty".
    let key: String
    /// The records that share this key.
    let records: [FileRecord]
}

/// Finds duplicate files using various strategies: by name, size, content hash,
/// empty files/directories, and directory child count.
actor DuplicateFinder {

    /// The index used for file lookups.
    private let index: InMemoryIndex

    /// Create a duplicate finder backed by the given index.
    ///
    /// - Parameter index: The in-memory index to enumerate records from.
    init(index: InMemoryIndex) {
        self.index = index
    }

    // MARK: - By Name

    /// Group records by normalized (lowercased) file name.
    /// Returns only groups with two or more records.
    func findByName() async -> [DuplicateGroup] {
        let records = await index.allRecords()
        var grouped: [String: [FileRecord]] = [:]

        for record in records {
            let key = record.name.lowercased()
            grouped[key, default: []].append(record)
        }

        return grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(key: $0.key, records: $0.value) }
            .sorted { $0.key < $1.key }
    }

    // MARK: - By Size

    /// Group records by file size. Returns only groups with two or more records.
    func findBySize() async -> [DuplicateGroup] {
        let records = await index.allRecords()
        var grouped: [Int64: [FileRecord]] = [:]

        for record in records {
            grouped[record.size, default: []].append(record)
        }

        return grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(key: String($0.key), records: $0.value) }
            .sorted { $0.key < $1.key }
    }

    // MARK: - By Hash

    /// For the given file paths, group by SHA-256 content hash.
    /// Only returns groups with two or more records sharing the same hash.
    /// The caller should pre-filter to same-size files for efficiency.
    func findByHash(paths: [String]) async -> [DuplicateGroup] {
        let allRecords = await index.allRecords()
        let pathToRecord = Dictionary(uniqueKeysWithValues: allRecords.map { ($0.path, $0) })

        // Compute hashes for requested paths
        var hashed: [(path: String, hash: String)] = []
        for path in paths {
            if let hash = FileHasher.sha256(ofFileAtPath: path) {
                hashed.append((path, hash))
            }
        }

        // Group by hash
        var grouped: [String: [FileRecord]] = [:]
        for entry in hashed {
            if let record = pathToRecord[entry.path] {
                grouped[entry.hash, default: []].append(record)
            }
        }

        return grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(key: $0.key, records: $0.value) }
            .sorted { $0.key < $1.key }
    }

    // MARK: - Empty Files & Directories

    /// Find zero-byte files and directories with no children in the index.
    func findEmpty() async -> [FileRecord] {
        let records = await index.allRecords()

        // Collect all directory paths that have at least one child
        var directorysWithChildren = Set<String>()
        for record in records {
            if !record.isDirectory {
                directorysWithChildren.insert(record.parentPath)
            }
        }

        var empties: [FileRecord] = []
        for record in records {
            if !record.isDirectory && record.size == 0 {
                // Zero-byte file
                empties.append(record)
            } else if record.isDirectory && !directorysWithChildren.contains(record.path) {
                // Directory with no children in the index
                empties.append(record)
            }
        }

        return empties.sorted { $0.id < $1.id }
    }

    // MARK: - By Child Count

    /// Group directories by their number of direct children.
    /// Only returns groups where the child count >= minCount.
    func findByChildCount(minCount: Int = 1) async -> [DuplicateGroup] {
        let records = await index.allRecords()

        // Count children per parent path
        var childCounts: [String: Int] = [:]
        for record in records {
            if !record.isDirectory {
                childCounts[record.parentPath, default: 0] += 1
            }
        }

        // Group directories by their child count
        var grouped: [Int: [FileRecord]] = [:]
        for record in records {
            guard record.isDirectory else { continue }
            let count = childCounts[record.path] ?? 0
            if count >= minCount {
                grouped[count, default: []].append(record)
            }
        }

        return grouped
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(key: String($0.key), records: $0.value) }
            .sorted { $0.key < $1.key }
    }
}
