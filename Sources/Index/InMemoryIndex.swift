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

    /// Create an index with a custom initial path-hash capacity. For testing
    /// resize logic at small scale; production uses `init()`.
    internal init(pathHashCap: UInt32) {
        _idx = cindex_create_with_path_cap(pathHashCap)
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
    public var totalRecords: Int { _idx != nil ? Int(cindex_total_records(_idx)) : 0 }
    public var isEmpty: Bool { count == 0 }

    /// Expose the raw CIndex pointer for direct C operations (C scanner, etc.).
    /// The pointer remains valid as long as this actor is alive.
    public func getCIndexPointer() -> OpaquePointer? {
        return _idx
    }

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
        guard let idx = _idx else { return [] }
        // Match the volume root exactly and everything beneath it. Normalize so
        // "/Volumes/USB" matches "/Volumes/USB" and "/Volumes/USB/..." but not
        // "/Volumes/USB Drive".
        let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        var removed: [UInt32] = []
        for record in allRecords() {
            if record.path == volumePath || record.path.hasPrefix(prefix) {
                cindex_remove(idx, record.id)
                removed.append(record.id)
            }
        }
        return removed
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

    // MARK: - Substring Search

    public func searchSubstring(query: String) -> [FileRecord] {
        guard let idx = _idx else { return [] }
        let lowered = query.precomposedStringWithCanonicalMapping.lowercased()
        guard !lowered.isEmpty else { return [] }

        var ids: UnsafeMutablePointer<UInt32>? = nil
        let count = lowered.withCString { cstr in
            cindex_search_substring(idx, cstr, &ids, 0)
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

    public func searchSubstring(query: String, limit: Int) -> [FileRecord] {
        guard let idx = _idx else { return [] }
        let lowered = query.precomposedStringWithCanonicalMapping.lowercased()
        guard !lowered.isEmpty else { return [] }

        var ids: UnsafeMutablePointer<UInt32>? = nil
        let count = lowered.withCString { cstr in
            cindex_search_substring(idx, cstr, &ids, UInt32(limit))
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
        guard let idx = _idx else { return [] }
        var results: [FileRecord] = []
        results.reserveCapacity(Int(cindex_total_records(idx)))

        _ = withUnsafeMutablePointer(to: &results) { ptr in
            cindex_iterate(idx, { (id, name, originalName, path, parentPath, isDir, size, createdAt, modifiedAt, userData) in
                guard let userData else { return }
                let resultsPtr = userData.assumingMemoryBound(to: [FileRecord].self)
                let origName = originalName != nil ? String(cString: originalName!) : ""
                let record = FileRecord(
                    id: id,
                    name: name != nil ? String(cString: name!).precomposedStringWithCanonicalMapping : "",
                    originalName: origName,
                    path: path != nil ? String(cString: path!) : "",
                    parentPath: parentPath != nil ? String(cString: parentPath!) : "",
                    isDirectory: isDir,
                    size: size,
                    createdAt: Date(timeIntervalSince1970: Double(createdAt)),
                    modifiedAt: Date(timeIntervalSince1970: Double(modifiedAt)),
                    extension: dfDeriveExtension(name: origName, isDirectory: isDir)
                )
                resultsPtr.pointee.append(record)
            }, ptr)
        }
        return results
    }

    // MARK: - C Scanner (zero-allocation scan)

    /// Run the C file scanner over `rootPath`, inserting records directly into the C index.
    /// Zero Swift String/FileRecord allocations during the scan — fts(3) traverses the
    /// filesystem and calls cindex_insert directly with C strings.
    ///
    /// This method is synchronous (blocks the calling thread). Run it from a `Task.detached`
    /// to avoid blocking the actor or the main cooperative thread pool.
    ///
    /// - Parameters:
    ///   - rootPath: The directory to scan.
    ///   - skipNames: Directory names to skip (e.g. ".git", "node_modules").
    ///   - skipFiles: File basenames to skip (e.g. ".DS_Store").
    ///   - skipExtensions: File extensions to skip (e.g. "o", "pyc").
    ///   - skipPaths: Path suffix patterns to skip (e.g. "/Library/Caches").
    ///   - maxDepth: Maximum directory depth, or -1 for unlimited.
    ///   - onProgress: Called every 100 files with (filesScanned, dirsScanned).
    ///   - onError: Called for non-fatal errors with (path, reason).
    /// - Returns: The number of files scanned (excluding directories and skipped items).
    public func runCScan(
        rootPath: String,
        skipNames: [String],
        skipFiles: [String],
        skipExtensions: [String],
        skipPaths: [String],
        maxDepth: Int32,
        onProgress: (@convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Bool)?,
        onError: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
        userData: UnsafeMutableRawPointer?
    ) -> UInt32 {
        guard let idx = _idx else { return 0 }

        let scanner = cscanner_create()!
        defer { cscanner_destroy(scanner) }

        // Convert Swift strings to C strings (as UnsafePointer for const char*)
        let cSkipNames = skipNames.map { UnsafePointer<CChar>?(strdup($0)) }
        let cSkipFiles = skipFiles.map { UnsafePointer<CChar>?(strdup($0)) }
        let cSkipExts = skipExtensions.map { UnsafePointer<CChar>?(strdup($0)) }
        let cSkipPaths = skipPaths.map { UnsafePointer<CChar>?(strdup($0)) }
        defer {
            cSkipNames.forEach { free(UnsafeMutablePointer(mutating: $0)) }
            cSkipFiles.forEach { free(UnsafeMutablePointer(mutating: $0)) }
            cSkipExts.forEach { free(UnsafeMutablePointer(mutating: $0)) }
            cSkipPaths.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        }

        // Configure scanner
        cSkipNames.withUnsafeBufferPointer { buf in
            cscanner_set_skip_names(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cSkipFiles.withUnsafeBufferPointer { buf in
            cscanner_set_skip_files(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cSkipExts.withUnsafeBufferPointer { buf in
            cscanner_set_skip_extensions(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cSkipPaths.withUnsafeBufferPointer { buf in
            cscanner_set_skip_paths(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cscanner_set_max_depth(scanner, maxDepth)
        cscanner_set_follow_symlinks(scanner, false)

        // Run the scan — blocks until complete or cancelled
        return cscanner_scan(scanner, idx, rootPath, onProgress, onError, userData)
    }

    /// Run the GCD-based parallel C scanner. Same semantics as ``runCScan`` but
    /// partitions the top-level children of `rootPath` across GCD worker threads
    /// (architecture inspired by github.com/seeyebe/rq). Faster on multi-core
    /// for wide directory trees; same zero-allocation property.
    public func runParallelCScan(
        rootPath: String,
        skipNames: [String],
        skipFiles: [String],
        skipExtensions: [String],
        skipPaths: [String],
        maxDepth: Int32,
        onProgress: (@convention(c) (UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Bool)?,
        onError: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
        userData: UnsafeMutableRawPointer?
    ) -> UInt32 {
        guard let idx = _idx else { return 0 }

        let scanner = cpscanner_create()!
        defer { cpscanner_destroy(scanner) }

        let cSkipNames = skipNames.map { UnsafePointer<CChar>?(strdup($0)) }
        let cSkipFiles = skipFiles.map { UnsafePointer<CChar>?(strdup($0)) }
        let cSkipExts = skipExtensions.map { UnsafePointer<CChar>?(strdup($0)) }
        let cSkipPaths = skipPaths.map { UnsafePointer<CChar>?(strdup($0)) }
        defer {
            cSkipNames.forEach { free(UnsafeMutablePointer(mutating: $0)) }
            cSkipFiles.forEach { free(UnsafeMutablePointer(mutating: $0)) }
            cSkipExts.forEach { free(UnsafeMutablePointer(mutating: $0)) }
            cSkipPaths.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        }

        cSkipNames.withUnsafeBufferPointer { buf in
            cpscanner_set_skip_names(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cSkipFiles.withUnsafeBufferPointer { buf in
            cpscanner_set_skip_files(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cSkipExts.withUnsafeBufferPointer { buf in
            cpscanner_set_skip_extensions(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cSkipPaths.withUnsafeBufferPointer { buf in
            cpscanner_set_skip_paths(scanner, buf.baseAddress, UInt32(buf.count))
        }
        cpscanner_set_max_depth(scanner, maxDepth)
        cpscanner_set_follow_symlinks(scanner, false)

        return cpscanner_scan(scanner, idx, rootPath, onProgress, onError, userData)
    }

    /// Save all records to SQLite via a callback, using cindex_iterate to avoid
    /// creating a [FileRecord] array in memory.
    /// Calls `onRecord` for each record; the callback is responsible for batching.
    public func forEachRecord(_ body: @escaping (UInt32, String, String, String, String, Bool, Int64, Int64, Int64) -> Void) {
        guard let idx = _idx else { return }
        var mutableBody = body
        _ = withUnsafeMutablePointer(to: &mutableBody) { ptr in
            cindex_iterate(idx, { (id, name, originalName, path, parentPath, isDir, size, createdAt, modifiedAt, userData) in
                guard let userData else { return }
                let bodyPtr = userData.assumingMemoryBound(to: ((UInt32, String, String, String, String, Bool, Int64, Int64, Int64) -> Void).self)
                let n = name != nil ? String(cString: name!).precomposedStringWithCanonicalMapping : ""
                let on = originalName != nil ? String(cString: originalName!) : ""
                let p = path != nil ? String(cString: path!) : ""
                let pp = parentPath != nil ? String(cString: parentPath!) : ""
                bodyPtr.pointee(id, n, on, p, pp, isDir, size, createdAt, modifiedAt)
            }, ptr)
        }
    }

    // MARK: - Snapshot

    public func snapshot() -> IndexSnapshot {
        IndexSnapshot(records: allRecords())
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
            extension: dfDeriveExtension(name: name, isDirectory: isDir)
        )
    }
}

// MARK: - IndexSnapshot

/// An immutable point-in-time copy of the index. Captured eagerly at
/// ``InMemoryIndex/snapshot()`` call time, so later mutations to the live
/// index do not affect it (snapshot isolation).
public struct IndexSnapshot: Sendable {
    private let records: [FileRecord]

    public init() { self.records = [] }
    init(records: [FileRecord]) { self.records = records }

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }

    public func allRecords() -> [FileRecord] { records }

    public func record(atPath path: String) -> FileRecord? {
        records.first { $0.path == path }
    }
}

/// Derive a file's extension from its name. The C index stores only the name
/// (not the extension), so we derive it for `ext:` filtering (SearchFilter) and
/// GUI display. nil for directories or extensionless names. Top-level (not a
/// method) so it can be called from `@convention(c)` iterate callbacks.
private func dfDeriveExtension(name: String, isDirectory: Bool) -> String? {
    if isDirectory { return nil }
    let ext = (name as NSString).pathExtension
    return ext.isEmpty ? nil : ext.lowercased()
}
