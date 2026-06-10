import Foundation
import Testing
@testable import DeepFinderSearch

@Suite("SearchBookmark")
struct SearchBookmarkTests {

    // MARK: - Helpers

    private func makeBookmark(
        id: UUID = UUID(),
        name: String = "Test Bookmark",
        query: String = "*.pdf"
    ) -> SearchBookmark {
        SearchBookmark(id: id, name: name, query: query, createdAt: Date())
    }

    private func tmpFilePath() -> String {
        let dir = NSTemporaryDirectory()
        return "\(dir)SearchBookmarkTests-\(UUID().uuidString).json"
    }

    // MARK: - Tests

    @Test("Add and retrieve bookmark")
    func testAddAndRetrieve() async throws {
        let store = BookmarkStore()
        let bookmark = makeBookmark()

        try await store.add(bookmark)

        let all = await store.getAll()
        #expect(all.count == 1)
        #expect(all[0] == bookmark)
    }

    @Test("Remove bookmark by ID")
    func testRemoveById() async throws {
        let store = BookmarkStore()
        let id = UUID()
        let bookmark = makeBookmark(id: id)

        try await store.add(bookmark)
        try await store.remove(id: id)

        let all = await store.getAll()
        #expect(all.isEmpty)
    }

    @Test("Find by name prefix")
    func testFindByNamePrefix() async throws {
        let store = BookmarkStore()
        try await store.add(makeBookmark(name: "PDF Files", query: "*.pdf"))
        try await store.add(makeBookmark(name: "PDF Reports", query: "report*.pdf"))
        try await store.add(makeBookmark(name: "Images", query: "*.png"))

        let found = await store.find(name: "PDF")
        #expect(found.count == 2)
    }

    @Test("Persist and reload round-trip")
    func testPersistAndReload() async throws {
        let path = tmpFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let bookmark = makeBookmark(name: "Persistent", query: "*.swift")

        // Write via first store
        let store1 = BookmarkStore(filePath: path)
        try await store1.add(bookmark)

        // Reload via second store
        let store2 = BookmarkStore(filePath: path)
        let all = await store2.getAll()
        #expect(all.count == 1)
        #expect(all[0].name == "Persistent")
        #expect(all[0].query == "*.swift")
    }

    @Test("Max 100 limit enforced")
    func testMax100Limit() async throws {
        let store = BookmarkStore()

        // Add 100 bookmarks
        for i in 0..<100 {
            try await store.add(makeBookmark(name: "BM \(i)", query: "q\(i)"))
        }

        let all = await store.getAll()
        #expect(all.count == 100)

        // 101st should throw
        do {
            try await store.add(makeBookmark(name: "Overflow", query: "overflow"))
            Issue.record("Expected BookmarkError.limitExceeded to be thrown")
        } catch let error as BookmarkError {
            #expect(error == .limitExceeded)
        }
    }

    @Test("Duplicate name allowed")
    func testDuplicateNameAllowed() async throws {
        let store = BookmarkStore()

        try await store.add(makeBookmark(name: "Same Name", query: "*.pdf"))
        try await store.add(makeBookmark(name: "Same Name", query: "*.doc"))

        let all = await store.getAll()
        #expect(all.count == 2)
    }

    @Test("Empty store returns empty array")
    func testEmptyStoreReturnsEmpty() async {
        let store = BookmarkStore()
        let all = await store.getAll()
        #expect(all.isEmpty)
    }

    @Test("File permissions 600")
    func testFilePermissions600() async throws {
        let path = tmpFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = BookmarkStore(filePath: path)
        try await store.add(makeBookmark())

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = attrs[.posixPermissions] as? Int
        #expect(perm == 0o600)
    }
}
