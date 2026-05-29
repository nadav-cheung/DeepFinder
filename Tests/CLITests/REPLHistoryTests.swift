import Testing
import Foundation
@testable import DeepFinder

@Suite("REPLHistory")
struct REPLHistoryTests {

    // MARK: - Helpers

    /// Creates a unique temp directory for each test.
    private func makeTempDir() -> String {
        let tmp = NSTemporaryDirectory()
            + "REPLHistoryTests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true
        )
        return tmp
    }

    /// Full path for the history file in a given temp directory.
    private func historyPath(in dir: String) -> String {
        dir + "/history.txt"
    }

    // MARK: - 1. Add and retrieve entries

    @Test("Add and retrieve entries")
    func testAddAndRetrieve() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir))
        await history.add("first query")
        await history.add("second query")

        let entries = await history.recent(10)
        #expect(entries == ["first query", "second query"])
    }

    // MARK: - 2. Max entries limit respected

    @Test("Max entries limit respected")
    func testMaxEntriesLimit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir), maxEntries: 3)
        for i in 0..<5 {
            await history.add("query \(i)")
        }

        let entries = await history.recent(10)
        // Should keep only the last 3: query 2, query 3, query 4
        #expect(entries == ["query 2", "query 3", "query 4"])
        let count = await history.count
        #expect(count == 3)
    }

    // MARK: - 3. Consecutive duplicates skipped

    @Test("Consecutive duplicates are skipped")
    func testConsecutiveDuplicatesSkipped() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir))
        await history.add("hello")
        await history.add("hello")
        await history.add("hello")
        await history.add("world")

        let entries = await history.recent(10)
        #expect(entries == ["hello", "world"])
    }

    // MARK: - 4. Non-consecutive duplicates kept

    @Test("Non-consecutive duplicates are kept")
    func testNonConsecutiveDuplicatesKept() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir))
        await history.add("hello")
        await history.add("world")
        await history.add("hello")

        let entries = await history.recent(10)
        #expect(entries == ["hello", "world", "hello"])
    }

    // MARK: - 5. Load from file round-trip

    @Test("Load from file round-trip: save then load")
    func testSaveAndLoadRoundTrip() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = historyPath(in: dir)

        // Write some entries
        let history1 = REPLHistory(filePath: path)
        await history1.add("alpha")
        await history1.add("beta")
        await history1.add("gamma")
        try await history1.save()

        // Load into a fresh instance
        let history2 = REPLHistory(filePath: path)
        try await history2.load()

        let entries = await history2.recent(10)
        #expect(entries == ["alpha", "beta", "gamma"])
    }

    // MARK: - 6. Empty file loads as empty

    @Test("Empty or missing file loads as empty")
    func testEmptyFileLoadsAsEmpty() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = historyPath(in: dir)
        // File does not exist yet

        let history = REPLHistory(filePath: path)
        try await history.load()

        let count = await history.count
        #expect(count == 0)
    }

    // MARK: - 7. Save creates file with correct permissions

    @Test("Save creates file with permissions 0600")
    func testSaveFilePermissions() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = historyPath(in: dir)
        let history = REPLHistory(filePath: path)
        await history.add("secret query")
        try await history.save()

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    // MARK: - 8. Recent returns last N entries

    @Test("Recent returns last N entries")
    func testRecentReturnsLastN() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir))
        for i in 0..<10 {
            await history.add("q\(i)")
        }

        let recent = await history.recent(3)
        #expect(recent == ["q7", "q8", "q9"])
    }

    // MARK: - 9. Search by prefix

    @Test("Search by prefix filters entries")
    func testSearchByPrefix() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir))
        await history.add("find hello")
        await history.add("search world")
        await history.add("find goodbye")
        await history.add("locate file")

        let results = await history.search(prefix: "find")
        #expect(results == ["find hello", "find goodbye"])
    }

    // MARK: - 10. Clear removes all entries

    @Test("Clear removes all entries")
    func testClearRemovesAll() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let history = REPLHistory(filePath: historyPath(in: dir))
        await history.add("one")
        await history.add("two")
        await history.clear()

        let count = await history.count
        #expect(count == 0)
        let entries = await history.recent(10)
        #expect(entries.isEmpty)
    }
}
