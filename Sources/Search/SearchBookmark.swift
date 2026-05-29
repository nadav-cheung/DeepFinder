import Foundation

// MARK: - SearchBookmark

/// A saved search query that a user can recall later.
struct SearchBookmark: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let query: String
    let createdAt: Date

    init(
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

enum BookmarkError: Error, Equatable {
    case limitExceeded
    case notFound
}

// MARK: - BookmarkStore

/// Thread-safe storage for search bookmarks.
/// When `filePath` is nil, operates in-memory only (useful for testing).
/// When `filePath` is provided, bookmarks are persisted as JSON with atomic writes.
actor BookmarkStore {

    private static let maxBookmarks = 100

    private var bookmarks: [SearchBookmark] = []
    private let filePath: String?

    init(filePath: String? = nil) {
        self.filePath = filePath
        if let filePath {
            bookmarks = Self.loadStatic(from: filePath)
        }
    }

    func add(_ bookmark: SearchBookmark) throws {
        guard bookmarks.count < Self.maxBookmarks else {
            throw BookmarkError.limitExceeded
        }
        bookmarks.append(bookmark)
        try save()
    }

    func remove(id: UUID) throws {
        let before = bookmarks.count
        bookmarks.removeAll { $0.id == id }
        guard bookmarks.count < before else {
            throw BookmarkError.notFound
        }
        try save()
    }

    func getAll() -> [SearchBookmark] {
        bookmarks
    }

    func find(name prefix: String) -> [SearchBookmark] {
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
        try FileManager.default.moveItem(atPath: tmp, toPath: filePath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: filePath
        )
    }

    private static func loadStatic(from path: String) -> [SearchBookmark] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        return (try? JSONDecoder().decode([SearchBookmark].self, from: data)) ?? []
    }
}
