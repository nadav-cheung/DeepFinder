import Foundation
import Testing
@testable import DeepFinderIndex

@Suite("InMemoryIndex")
struct InMemoryIndexTests {

    /// Helper: create a FileRecord for testing.
    private func makeRecord(
        id: UInt32 = 1,
        name: String = "report.pdf",
        path: String = "/Users/test/Documents/report.pdf",
        parentPath: String = "/Users/test/Documents",
        isDirectory: Bool = false,
        size: Int64 = 1024,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        extension ext: String? = "pdf"
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name.precomposedStringWithCanonicalMapping,
            originalName: name,
            path: path,
            parentPath: parentPath,
            isDirectory: isDirectory,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: ext
        )
    }

    // MARK: - 1. Empty Index

    @Test("空索引搜索返回空")
    func emptyIndexSearchReturnsEmpty() async {
        let index = InMemoryIndex()
        let results = await index.search(query: "test")
        #expect(results.isEmpty)
    }

    // MARK: - 2. Insert and Search

    @Test("插入文件后可搜索")
    func insertThenSearch() async {
        let index = InMemoryIndex()
        let record = makeRecord(id: 1, name: "report.pdf")
        await index.insert(record)

        let results = await index.search(query: "report")
        #expect(results.count == 1)
        #expect(results[0].id == 1)
        #expect(results[0].name == "report.pdf")
    }

    // MARK: - 3. Prefix Search via Trie

    @Test("前缀搜索")
    func prefixSearch() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "apple.txt"))
        await index.insert(makeRecord(id: 2, name: "application.pdf"))
        await index.insert(makeRecord(id: 3, name: "banana.txt"))

        // "app" should find apple and application via Trie prefix match
        let results = await index.search(query: "app")
        let ids = results.map(\.id).sorted()
        #expect(ids == [1, 2])
    }

    // MARK: - 4. Substring Search via FullSubstringMap

    @Test("子串搜索")
    func substringSearch() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "my_report_final.pdf"))
        await index.insert(makeRecord(id: 2, name: "summary.doc"))

        // "report" is a substring (not prefix) — FullSubstringMap handles this
        let results = await index.search(query: "report")
        #expect(results.count == 1)
        #expect(results[0].id == 1)
    }

    // MARK: - 5. Long Filename via TrigramIndex

    @Test("长文件名搜索")
    func longFilenameSearch() async {
        let index = InMemoryIndex()
        // 65+ characters — too long for FullSubstringMap, handled by TrigramIndex
        let longName = "this_is_a_very_long_filename_that_exceeds_the_64_character_limit_for_substring_map_v2.txt"
        await index.insert(makeRecord(id: 1, name: longName))
        await index.insert(makeRecord(id: 2, name: "short.txt"))

        let results = await index.search(query: "substring_map")
        #expect(results.count == 1)
        #expect(results[0].id == 1)
    }

    // MARK: - 6. Pinyin Search

    @Test("拼音搜索")
    func pinyinSearch() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "季度报告.pdf"))
        await index.insert(makeRecord(id: 2, name: "english.txt"))

        // Search by pinyin "jidu" — should find 季度报告
        let results = await index.search(query: "jidu")
        #expect(results.count == 1)
        #expect(results[0].id == 1)
    }

    // MARK: - 7. Remove

    @Test("删除文件后不再可搜索")
    func removeThenNotFound() async {
        let index = InMemoryIndex()
        let record = makeRecord(id: 1, name: "deleteme.txt")
        await index.insert(record)

        // Confirm it's there
        var results = await index.search(query: "deleteme")
        #expect(results.count == 1)

        // Remove it
        await index.remove(id: 1)

        // Confirm it's gone — search by name substring
        results = await index.search(query: "deleteme")
        #expect(results.isEmpty)

        // Also gone from prefix search
        results = await index.search(query: "del")
        #expect(results.isEmpty)
    }

    // MARK: - 8. Batch Insert

    @Test("批量插入")
    func batchInsert() async {
        let index = InMemoryIndex()
        let names = ["alpha.txt", "beta.pdf", "gamma.doc", "delta.png"]
        for (i, name) in names.enumerated() {
            await index.insert(makeRecord(id: UInt32(i + 1), name: name))
        }

        let count = await index.count
        #expect(count == 4)

        // "a" should match alpha, beta, gamma, delta (all contain "a")
        let results = await index.search(query: "a")
        let ids = results.map(\.id).sorted()
        #expect(ids == [1, 2, 3, 4])
    }

    // MARK: - 9. NFC Normalization

    @Test("NFC 统一化")
    func nfcNormalization() async {
        let index = InMemoryIndex()
        // Insert with NFD form of "café"
        let nfdName = "cafe\u{0301}.txt"
        await index.insert(makeRecord(id: 1, name: nfdName))

        // Search with NFC form
        let nfcQuery = "caf\u{00E9}"
        let results = await index.search(query: nfcQuery)
        #expect(results.count == 1)
        #expect(results[0].id == 1)
    }

    // MARK: - 10. Case-Insensitive

    @Test("大小写不敏感")
    func caseInsensitive() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "Report.PDF"))

        // Lowercase query should find uppercase name
        let results = await index.search(query: "report")
        #expect(results.count == 1)
        #expect(results[0].id == 1)

        // Uppercase query should also work
        let results2 = await index.search(query: "REPORT")
        #expect(results2.count == 1)
        #expect(results2[0].id == 1)
    }

    // MARK: - 11. Search Returns FileRecord

    @Test("搜索返回 FileRecord")
    func searchReturnsFileRecord() async {
        let index = InMemoryIndex()
        let record = makeRecord(
            id: 42,
            name: "thesis.pdf",
            path: "/Users/alice/Documents/thesis.pdf",
            parentPath: "/Users/alice/Documents",
            isDirectory: false,
            size: 5_000_000,
            extension: "pdf"
        )
        await index.insert(record)

        let results = await index.search(query: "thesis")
        #expect(results.count == 1)
        let found = results[0]
        #expect(found.id == 42)
        #expect(found.name == "thesis.pdf")
        #expect(found.path == "/Users/alice/Documents/thesis.pdf")
        #expect(found.parentPath == "/Users/alice/Documents")
        #expect(found.isDirectory == false)
        #expect(found.size == 5_000_000)
        #expect(found.extension == "pdf")
    }

    // MARK: - 12. Count Property

    @Test("count 属性")
    func countProperty() async {
        let index = InMemoryIndex()
        #expect(await index.count == 0)
        #expect(await index.isEmpty)

        await index.insert(makeRecord(id: 1, name: "a.txt"))
        #expect(await index.count == 1)
        let notEmpty1 = await !index.isEmpty
        #expect(notEmpty1)

        await index.insert(makeRecord(id: 2, name: "b.txt"))
        #expect(await index.count == 2)

        await index.remove(id: 1)
        #expect(await index.count == 1)

        await index.remove(id: 2)
        #expect(await index.count == 0)
        let emptyFinal = await index.isEmpty
        #expect(emptyFinal)
    }

    // MARK: - 13. Deduplication

    @Test("搜索结果去重")
    func searchDeduplication() async {
        let index = InMemoryIndex()
        // A file whose name starts with "test" and also contains "test" as substring.
        // Trie (prefix) and FullSubstringMap (substring) should both find it,
        // but it should appear only once in results.
        await index.insert(makeRecord(id: 1, name: "testfile.txt"))

        let results = await index.search(query: "test")
        #expect(results.count == 1)
        #expect(results[0].id == 1)
    }

    // MARK: - 14. Empty Query

    @Test("空查询返回空")
    func emptyQueryReturnsEmpty() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "file.txt"))

        let results = await index.search(query: "")
        #expect(results.isEmpty)
    }

    // MARK: - 15. Remove by Path

    @Test("按路径删除文件")
    func removeByPath() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "report.pdf", path: "/Users/test/Documents/report.pdf"))
        await index.insert(makeRecord(id: 2, name: "notes.txt", path: "/Users/test/Documents/notes.txt"))

        let removed = await index.removeByPath("/Users/test/Documents/report.pdf")
        #expect(removed)
        #expect(await index.count == 1)

        let results = await index.search(query: "report")
        #expect(results.isEmpty)
    }

    @Test("按路径删除不存在的文件返回 false")
    func removeByPathNotFound() async {
        let index = InMemoryIndex()
        let removed = await index.removeByPath("/nonexistent/path/file.txt")
        #expect(removed == false)
    }

    @Test("按路径删除同名不同路径的文件")
    func removeByPathSameNameDifferentPath() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "report.pdf", path: "/Users/test/Documents/report.pdf"))
        await index.insert(makeRecord(id: 2, name: "report.pdf", path: "/Users/test/Desktop/report.pdf"))

        let removed = await index.removeByPath("/Users/test/Desktop/report.pdf")
        #expect(removed)
        #expect(await index.count == 1)

        // The Documents version should still be searchable
        let results = await index.search(query: "report")
        #expect(results.count == 1)
        #expect(results[0].path == "/Users/test/Documents/report.pdf")
    }

    // MARK: - 16. Snapshot API

    @Test("snapshot 捕获当前索引状态")
    func snapshotCapturesCurrentState() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "alpha.txt"))
        await index.insert(makeRecord(id: 2, name: "beta.pdf"))

        let snapshot = await index.snapshot()
        #expect(snapshot.count == 2)
        #expect(!snapshot.isEmpty)
    }

    @Test("snapshot 不受后续修改影响（快照隔离）")
    func snapshotIsolation() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "report.pdf"))

        let snapshot = await index.snapshot()
        #expect(snapshot.count == 1)

        // Mutate the live index after taking snapshot
        await index.insert(makeRecord(id: 2, name: "memo.txt"))
        #expect(await index.count == 2)

        // Snapshot should still see only the original record
        #expect(snapshot.count == 1)
    }

    @Test("snapshot 的 allRecords 返回所有记录")
    func snapshotAllRecords() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "first.txt"))
        await index.insert(makeRecord(id: 2, name: "second.pdf"))

        let snapshot = await index.snapshot()
        let records = snapshot.allRecords()
        #expect(records.count == 2)
    }

    @Test("snapshot 的 recordAtPath 查找记录")
    func snapshotRecordAtPath() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "report.pdf", path: "/docs/report.pdf"))

        let snapshot = await index.snapshot()
        let found = snapshot.record(atPath: "/docs/report.pdf")
        #expect(found != nil)
        #expect(found?.name == "report.pdf")

        let missing = snapshot.record(atPath: "/nonexistent")
        #expect(missing == nil)
    }

    @Test("空索引的 snapshot")
    func emptySnapshot() async {
        let index = InMemoryIndex()
        let snapshot = await index.snapshot()
        #expect(snapshot.count == 0)
        #expect(snapshot.isEmpty)
        #expect(snapshot.allRecords().isEmpty)
    }
}
