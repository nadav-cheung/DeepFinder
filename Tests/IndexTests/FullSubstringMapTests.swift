import Foundation
import Testing
@testable import DeepFinder

@Suite("FullSubstringMap")
struct FullSubstringMapTests {

    // MARK: - 1. 空	map 插入后可搜索

    @Test("空 map 插入后可搜索")
    func insertThenFind() {
        var map = FullSubstringMap()
        #expect(map.isEmpty)

        map.insert(name: "hello.txt", id: 1)
        let results = map.search(substring: "hello")
        #expect(results == [1])
        #expect(!map.isEmpty)
    }

    // MARK: - 2. 子串 O(1) 直查

    @Test("子串 O(1) 直查 — 任意子串匹配")
    func arbitrarySubstringMatches() {
        var map = FullSubstringMap()
        map.insert(name: "report.pdf", id: 10)

        // "port" is a substring of "report.pdf"
        #expect(map.search(substring: "port") == [10])
        // "rt.p" crosses the dot boundary
        #expect(map.search(substring: "rt.p") == [10])
    }

    // MARK: - 3. 大小写不敏感

    @Test("大小写不敏感")
    func caseInsensitive() {
        var map = FullSubstringMap()
        map.insert(name: "Report.PDF", id: 1)

        #expect(map.search(substring: "report.pdf") == [1])
        #expect(map.search(substring: "REPORT") == [1])
        #expect(map.search(substring: "pdf") == [1])
    }

    // MARK: - 4. 多个文件共享子串

    @Test("多个文件共享子串")
    func multipleFilesShareSubstring() {
        var map = FullSubstringMap()
        map.insert(name: "report_2024.pdf", id: 1)
        map.insert(name: "report_2025.pdf", id: 2)
        map.insert(name: "summary.doc", id: 3)

        let results = map.search(substring: "report")
        #expect(Set(results) == [1, 2])
    }

    // MARK: - 5. 前缀匹配

    @Test("前缀匹配")
    func prefixIsSubstring() {
        var map = FullSubstringMap()
        map.insert(name: "readme.md", id: 5)

        #expect(map.search(substring: "read") == [5])
        #expect(map.search(substring: "r") == [5])
    }

    // MARK: - 6. 后缀匹配

    @Test("后缀匹配")
    func suffixIsSubstring() {
        var map = FullSubstringMap()
        map.insert(name: "archive.zip", id: 7)

        #expect(map.search(substring: "zip") == [7])
        #expect(map.search(substring: ".zip") == [7])
    }

    // MARK: - 7. 中间子串匹配

    @Test("中间子串匹配")
    func middleSubstring() {
        var map = FullSubstringMap()
        map.insert(name: "my_photo_backup.jpg", id: 3)

        #expect(map.search(substring: "photo") == [3])
        #expect(map.search(substring: "_photo_") == [3])
        #expect(map.search(substring: "backup") == [3])
    }

    // MARK: - 8. 单字符搜索

    @Test("单字符搜索")
    func singleCharSearch() {
        var map = FullSubstringMap()
        map.insert(name: "a.txt", id: 1)
        map.insert(name: "b.txt", id: 2)

        // "a" appears in "a.txt"
        let aResults = map.search(substring: "a")
        #expect(aResults.contains(1))

        // "." appears in both
        let dotResults = map.search(substring: ".")
        #expect(Set(dotResults) == [1, 2])
    }

    // MARK: - 9. 空字符串搜索由调用方防护
    // Empty substring is a precondition violation — callers (InMemoryIndex) guard against it.
    // No test needed: the precondition enforces correct usage at development time.

    // MARK: - 10. 不存在的子串返回空

    @Test("不存在的子串返回空")
    func nonExistentReturnsEmpty() {
        var map = FullSubstringMap()
        map.insert(name: "hello.txt", id: 1)

        #expect(map.search(substring: "xyz") == [])
        #expect(map.search(substring: "helloo") == [])
    }

    // MARK: - 11. 删除后不再可搜索

    @Test("删除后不再可搜索")
    func removeThenNotFound() {
        var map = FullSubstringMap()
        map.insert(name: "delete_me.txt", id: 42)

        #expect(map.search(substring: "delete") == [42])

        map.remove(name: "delete_me.txt", id: 42)

        #expect(map.search(substring: "delete") == [])
        #expect(map.search(substring: "delete_me") == [])
        #expect(map.count == 0)
    }

    // MARK: - 12. 删除不影响共享子串的条目

    @Test("删除不影响共享子串的条目")
    func removeOneKeepsSharedSubstrings() {
        var map = FullSubstringMap()
        map.insert(name: "test_a.txt", id: 1)
        map.insert(name: "test_b.txt", id: 2)

        map.remove(name: "test_a.txt", id: 1)

        // "test" should still find id 2
        #expect(map.search(substring: "test") == [2])
        // "test_a" should no longer find id 1
        #expect(map.search(substring: "test_a") == [])
        // "test_b" should still find id 2
        #expect(map.search(substring: "test_b") == [2])
        #expect(map.count == 1)
    }

    // MARK: - 13. 长文件名 (>64 chars) 不插入

    @Test("长文件名 (>64 chars) 不插入")
    func longNamesRejected() {
        var map = FullSubstringMap()

        // Exactly 64 chars — should be accepted
        let name64 = String(repeating: "a", count: 64)
        map.insert(name: name64, id: 1)
        #expect(map.search(substring: "a") == [1])
        #expect(map.count == 1)

        // 65 chars — should be rejected
        let name65 = String(repeating: "b", count: 65)
        map.insert(name: name65, id: 2)
        #expect(map.search(substring: "b") == [])
        #expect(map.count == 1)
    }

    // MARK: - 14. count 属性

    @Test("count 属性")
    func countTracksEntries() {
        var map = FullSubstringMap()
        #expect(map.count == 0)

        map.insert(name: "one.txt", id: 1)
        #expect(map.count == 1)

        map.insert(name: "two.txt", id: 2)
        #expect(map.count == 2)

        map.insert(name: "three.txt", id: 3)
        #expect(map.count == 3)

        map.remove(name: "one.txt", id: 1)
        #expect(map.count == 2)

        // Removing non-existent entry does not change count
        map.remove(name: "nonexistent.txt", id: 99)
        #expect(map.count == 2)
    }

    // MARK: - 15. NFC 统一化

    @Test("NFC 统一化")
    func nfcNormalized() {
        var map = FullSubstringMap()

        // "é" (e + combining acute accent, NFD form)
        let nfdName = "résumé.pdf"
        // "é" (precomposed, NFC form)
        let nfcSubstring = "résumé"

        map.insert(name: nfdName.precomposedStringWithCanonicalMapping, id: 1)

        // Search with NFC form should find the NFD-inserted entry (both NFC after normalization)
        let results = map.search(substring: nfcSubstring)
        #expect(results == [1])
    }

    // MARK: - 16. Unicode 子串 (CJK)

    @Test("Unicode 子串 — CJK 字符")
    func unicodeCJK() {
        var map = FullSubstringMap()
        map.insert(name: "项目报告.pdf", id: 100)
        map.insert(name: "项目计划.pdf", id: 101)

        let results = map.search(substring: "项目")
        #expect(Set(results) == [100, 101])

        #expect(map.search(substring: "报告") == [100])
        #expect(map.search(substring: "计划") == [101])
    }
}
