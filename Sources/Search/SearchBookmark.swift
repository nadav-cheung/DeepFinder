// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex

// MARK: - SearchBookmark

/// A saved search query that a user can recall later.
///
/// Equality is based on `id` (UUID), allowing multiple bookmarks with the same name.
public struct SearchBookmark: Codable, Sendable, Equatable {
    /// Unique identifier for this bookmark.
    public let id: UUID
    /// User-visible display name.
    public let name: String
    /// The saved search query string.
    public let query: String
    /// When this bookmark was created.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        query: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = createdAt
    }
}

// MARK: - BookmarkError

/// Errors thrown by `BookmarkStore` operations.
public enum BookmarkError: Error, Equatable {
    /// The bookmark store has reached its maximum capacity (100).
    case limitExceeded
    /// The requested bookmark ID was not found in the store.
    case notFound
}

// MARK: - BookmarkStore

/// Thread-safe storage for search bookmarks.
/// When `filePath` is nil, operates in-memory only (useful for testing).
/// When `filePath` is provided, bookmarks are persisted as JSON with atomic writes.
public actor BookmarkStore {

    private static let maxBookmarks = Constants.Search.maxBookmarks

    /// In-memory bookmark list. Persisted to disk when `filePath` is non-nil.
    private var bookmarks: [SearchBookmark] = []

    /// Optional file path for JSON persistence. When nil, operates in-memory only.
    private let filePath: String?

    /// Create a bookmark store.
    ///
    /// - Parameter filePath: Path to persist bookmarks as JSON. Pass `nil` for
    ///   in-memory-only operation (useful for testing). When a path is provided,
    ///   existing bookmarks are loaded from disk on init.
    public init(filePath: String? = nil) {
        self.filePath = filePath
        if let filePath {
            bookmarks = Self.loadStatic(from: filePath)
        }
    }

    /// Add a bookmark. Throws `BookmarkError.limitExceeded` if the store is full.
    public func add(_ bookmark: SearchBookmark) throws {
        guard bookmarks.count < Self.maxBookmarks else {
            throw BookmarkError.limitExceeded
        }
        bookmarks.append(bookmark)
        try save()
    }

    /// Remove a bookmark by ID. Throws `BookmarkError.notFound` if the ID does not exist.
    public func remove(id: UUID) throws {
        let before = bookmarks.count
        bookmarks.removeAll { $0.id == id }
        guard bookmarks.count < before else {
            throw BookmarkError.notFound
        }
        try save()
    }

    /// Return all bookmarks in insertion order.
    public func getAll() -> [SearchBookmark] {
        bookmarks
    }

    /// Return bookmarks whose name starts with the given prefix.
    public func find(name prefix: String) -> [SearchBookmark] {
        bookmarks.filter { $0.name.hasPrefix(prefix) }
    }

    // MARK: - Private

    private func save() throws {
        guard let filePath else { return }
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(bookmarks)
        let tmp = filePath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        // Remove old file before rename (moveItem fails if destination exists)
        if FileManager.default.fileExists(atPath: filePath) {
            try FileManager.default.removeItem(atPath: filePath)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: filePath)
        try FileManager.default.setAttributes(
            [.posixPermissions: Product.privateFilePermissions], ofItemAtPath: filePath
        )
    }

    private static func loadStatic(from path: String) -> [SearchBookmark] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        return (try? JSONDecoder().decode([SearchBookmark].self, from: data)) ?? []
    }
}
