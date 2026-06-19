import Foundation
import Testing
@testable import DeepFinderIndex

@Suite("CTrigramIndex — substring search")
struct CTrigramIndexTests {

    /// Helper: create a FileRecord for testing.
    private func makeRecord(
        id: UInt32 = 1,
        name: String = "report.pdf",
        path: String? = nil,
        parentPath: String? = nil,
        isDirectory: Bool = false,
        size: Int64 = 1024,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        extension ext: String? = "pdf"
    ) -> FileRecord {
        let resolvedPath = path ?? "/Users/test/Documents/\(name)"
        let resolvedParent = parentPath ?? "/Users/test/Documents"
        return FileRecord(
            id: id,
            name: name.precomposedStringWithCanonicalMapping,
            originalName: name,
            path: resolvedPath,
            parentPath: resolvedParent,
            isDirectory: isDirectory,
            size: size,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            extension: ext
        )
    }

    // MARK: - 1. Basic substring

    @Test("基本子串搜索")
    func basicSubstring() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "README.md"))

        // Full lowercased name substring
        let results = await index.searchSubstring(query: "readme")
        #expect(results.count == 1)
        #expect(results[0].id == 1)

        // True substring (not prefix) within the name
        let results2 = await index.searchSubstring(query: "adme")
        #expect(results2.count == 1)
        #expect(results2[0].id == 1)
    }

    // MARK: - 2. Case insensitivity

    @Test("大小写不敏感")
    func caseInsensitive() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "Photo.JPEG"))

        let results = await index.searchSubstring(query: "photo")
        #expect(results.count == 1)
        #expect(results[0].id == 1)

        let results2 = await index.searchSubstring(query: "jpeg")
        #expect(results2.count == 1)
        #expect(results2[0].id == 1)
    }

    // MARK: - 3. CJK

    @Test("CJK 子串搜索")
    func cjkSubstring() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "张楠报告.pdf"))

        // Two-character substring from start
        let results = await index.searchSubstring(query: "张楠")
        #expect(results.count == 1)
        #expect(results[0].id == 1)

        // Single character (trigram index handles CJK natively via byte trigrams)
        let results2 = await index.searchSubstring(query: "楠")
        #expect(results2.count == 1)
        #expect(results2[0].id == 1)

        // Two-character substring from end
        let results3 = await index.searchSubstring(query: "报告")
        #expect(results3.count == 1)
        #expect(results3[0].id == 1)
    }

    // MARK: - 4. Short query (<3 bytes, linear-scan fallback)

    @Test("短查询回退线性扫描")
    func shortQueryLinearScan() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "ab.txt"))

        let results = await index.searchSubstring(query: "ab")
        #expect(results.count == 1)
        #expect(results[0].id == 1)
    }

    // MARK: - 5. No results

    @Test("无匹配返回空")
    func noResults() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "README.md"))

        let results = await index.searchSubstring(query: "zzzznone")
        #expect(results.isEmpty)
    }

    // MARK: - 6. Multiple matches

    @Test("多个匹配")
    func multipleMatches() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "test_a.txt", path: "/root/test_a.txt"))
        await index.insert(makeRecord(id: 2, name: "test_b.txt", path: "/root/test_b.txt"))
        await index.insert(makeRecord(id: 3, name: "other.log", path: "/root/other.log"))

        let results = await index.searchSubstring(query: "test")
        #expect(results.count == 2)

        let ids = results.map(\.id).sorted()
        #expect(ids == [1, 2])
    }

    // MARK: - 7. Remove

    @Test("删除后不再可搜索")
    func removeThenNotFound() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "config_backup.yaml"))

        var results = await index.searchSubstring(query: "backup")
        #expect(results.count == 1)

        await index.remove(id: 1)

        results = await index.searchSubstring(query: "backup")
        #expect(results.isEmpty)
    }

    // MARK: - 8. Empty query

    @Test("空查询不崩溃返回空")
    func emptyQueryDoesNotCrash() async {
        let index = InMemoryIndex()
        await index.insert(makeRecord(id: 1, name: "anything.txt"))

        let results = await index.searchSubstring(query: "")
        #expect(results.isEmpty)
    }
}
