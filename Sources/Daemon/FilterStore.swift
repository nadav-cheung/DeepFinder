// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import OSLog
import DeepFinderIndex

/// Persistent, thread-safe store for named filter macros (`SavedFilter`).
///
/// Mirrors `BookmarkStore`'s design: an actor with optional JSON persistence
/// (atomic write + rename, permissions 600). Lives in the Daemon module because
/// `SavedFilter` is defined alongside the IPC protocol there (a Search-layer
/// store would create a Search→Daemon dependency cycle).
///
/// Filters are keyed by `name` (upsert semantics): saving a name that already
/// exists replaces its expression. Equality is by `name`.
public actor FilterStore {

    /// In-memory filter list. Persisted when `filePath` is non-nil.
    private var filters: [SavedFilter] = []

    /// Optional JSON persistence path. `nil` = in-memory only (testing).
    private let filePath: String?

    /// Create a filter store, loading existing filters from disk when a path is given.
    public init(filePath: String? = nil) {
        self.filePath = filePath
        if let filePath {
            filters = Self.loadStatic(from: filePath)
        }
    }

    /// Upsert a filter by name. Replaces an existing filter with the same name.
    public func upsert(name: String, expression: String) {
        filters.removeAll { $0.name == name }
        filters.append(SavedFilter(name: name, expression: expression))
        persist()
    }

    /// Delete a filter by name. Returns `true` if a filter was removed.
    @discardableResult
    public func delete(name: String) -> Bool {
        let before = filters.count
        filters.removeAll { $0.name == name }
        let removed = filters.count < before
        if removed { persist() }
        return removed
    }

    /// All filters in insertion order.
    public func getAll() -> [SavedFilter] {
        filters
    }

    /// Look up a filter by exact name.
    public func find(name: String) -> SavedFilter? {
        filters.first { $0.name == name }
    }

    // MARK: - Private

    private func persist() {
        guard let filePath else { return }
        let dir = (filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(filters)
            let tmp = filePath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            if FileManager.default.fileExists(atPath: filePath) {
                try FileManager.default.removeItem(atPath: filePath)
            }
            try FileManager.default.moveItem(atPath: tmp, toPath: filePath)
            try FileManager.default.setAttributes(
                [.posixPermissions: Product.privateFilePermissions], ofItemAtPath: filePath
            )
        } catch {
            // Best-effort persistence; the in-memory store remains authoritative.
            Self.logger.error("FilterStore persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadStatic(from path: String) -> [SavedFilter] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([SavedFilter].self, from: data)) ?? []
    }

    private static let logger = Logger(subsystem: Product.daemonSubsystem, category: "filters")
}
