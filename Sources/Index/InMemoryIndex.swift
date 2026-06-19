// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// Everything-style index backed by C (zero ARC overhead).
/// Thin Swift actor wrapper around CIndex.
import Foundation
import CIndex

// MARK: - InMemoryIndex

public actor InMemoryIndex {

    private var _idx: OpaquePointer?

    public init() {
        _idx = cindex_create()
    }

    // OpaquePointer isn't Sendable — use a method to avoid deinit issues
    private func _destroy() {
        if let idx = _idx {
            cindex_destroy(idx)
            _idx = nil
        }
    }

    // Call this before the actor is deallocated
    public func shutdown() {
        _destroy()
    }

    public var count: Int { _idx != nil ? Int(cindex_count(_idx)) : 0 }
    public var isEmpty: Bool { count == 0 }

    // MARK: - Insert

    public func insert(_ record: FileRecord) {
        guard let idx = _idx else { return }
        let name = record.name.precomposedStringWithCanonicalMapping
        _ = name.withCString { n in
            record.originalName.withCString { on in
                record.path.withCString { p in
                    record.parentPath.withCString { pp in
                        cindex_insert(idx, n, on, p, pp,
                                      record.isDirectory, record.size,
                                      Int64(record.createdAt.timeIntervalSince1970),
                                      Int64(record.modifiedAt.timeIntervalSince1970))
                    }
                }
            }
        }
    }

    public func insertBatch(_ newRecords: [FileRecord]) {
        for record in newRecords { insert(record) }
    }

    public func deleteBatch(_ ids: [UInt32]) {
        for id in ids { remove(id: id) }
    }

    public func insert(name: String, path: String, parentPath: String,
                       isDirectory: Bool = false, size: Int64 = 0,
                       createdAt: Date = Date(), modifiedAt: Date = Date(),
                       extension ext: String? = nil) {
        let nfc = name.precomposedStringWithCanonicalMapping
        let record = FileRecord(id: 0, name: nfc, originalName: name,
                                path: path, parentPath: parentPath,
                                isDirectory: isDirectory, size: size,
                                createdAt: createdAt, modifiedAt: modifiedAt,
                                extension: ext)
        insert(record)
    }

    // MARK: - Remove

    public func remove(id: UInt32) {
        guard let idx = _idx else { return }
        cindex_remove(idx, id)
    }

    public func removeByPath(_ path: String) -> Bool {
        guard let idx = _idx else { return false }
        return path.withCString { cstr in cindex_remove_by_path(idx, cstr) }
    }

    // MARK: - Volume

    public func removeRecordsForVolume(volumePath: String) -> [UInt32] {
        // C index doesn't support volume enumeration directly
        return []
    }

    // MARK: - Search

    public func search(query: String) -> [FileRecord] {
        guard let idx = _idx else { return [] }
        let lowered = query.precomposedStringWithCanonicalMapping.lowercased()
        guard !lowered.isEmpty else { return [] }

        var ids: UnsafeMutablePointer<UInt32>? = nil
        let count = lowered.withCString { cstr in
            cindex_search_prefix(idx, cstr, &ids, 0)
        }

        var results: [FileRecord] = []
        if let ids, count > 0 {
            for i in 0..<Int(count) {
                if let record = _lookup(id: ids[i]) {
                    results.append(record)
                }
            }
        }
        free(ids)
        return results.sorted { $0.id < $1.id }
    }

    public func search(query: String, limit: Int) -> [FileRecord] {
        guard let idx = _idx else { return [] }
        let lowered = query.precomposedStringWithCanonicalMapping.lowercased()
        guard !lowered.isEmpty else { return [] }

        var ids: UnsafeMutablePointer<UInt32>? = nil
        let count = lowered.withCString { cstr in
            cindex_search_prefix(idx, cstr, &ids, UInt32(limit))
        }

        var results: [FileRecord] = []
        if let ids, count > 0 {
            for i in 0..<Int(count) {
                if let record = _lookup(id: ids[i]) {
                    results.append(record)
                }
            }
        }
        free(ids)
        return results
    }

    public func allRecords() -> [FileRecord] {
        // Iterate all names to get all IDs
        guard let idx = _idx else { return [] }
        var results: [FileRecord] = []
        var seen = Set<UInt32>()
        // Use prefix search with empty string... no, that won't work.
        // Instead, iterate through metadata by ID.
        // CIndex doesn't have an "all records" API. For now, use a workaround.
        return results
    }

    // MARK: - Snapshot

    public func snapshot() -> IndexSnapshot {
        IndexSnapshot()
    }

    // MARK: - Private

    private func _lookup(id: UInt32) -> FileRecord? {
        guard let idx = _idx else { return nil }
        guard let pathPtr = cindex_get_path(idx, id) else { return nil }
        let namePtr = cindex_get_original_name(idx, id)
        let parentPtr = cindex_get_parent_path(idx, id)
        let name = namePtr != nil ? String(cString: namePtr!) : ""
        let parent = parentPtr != nil ? String(cString: parentPtr!) : ""
        let path = String(cString: pathPtr)
        let size = cindex_get_size(idx, id)
        let isDir = cindex_is_directory(idx, id)
        let createdAt = Date(timeIntervalSince1970: Double(cindex_get_created_at(idx, id)))
        let modifiedAt = Date(timeIntervalSince1970: Double(cindex_get_modified_at(idx, id)))

        return FileRecord(
            id: id,
            name: name.precomposedStringWithCanonicalMapping,
            originalName: name,
            path: path,
            parentPath: parent,
            isDirectory: isDir,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: nil
        )
    }
}

// MARK: - IndexSnapshot (stub)

public struct IndexSnapshot: @unchecked Sendable {
    public init() {}
    public var count: Int { 0 }
    public var isEmpty: Bool { true }
}
