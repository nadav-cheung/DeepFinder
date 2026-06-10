import Foundation
import Testing
@testable import DeepFinderIndex

@Suite("TrigramIndex")
struct TrigramIndexTests {

    // MARK: - 1. 空索引搜索返回空

    @Test("空索引搜索返回空")
    func emptyIndexReturnsEmpty() {
        let index = TrigramIndex()
        #expect(index.count == 0)
        #expect(index.search(substring: "anything") == [])
    }

    // MARK: - 2. 插入后可搜索

    @Test("插入后可搜索")
    func insertThenSearch() {
        var index = TrigramIndex()
        index.insert(name: "readme.txt", id: 1)

        let results = index.search(substring: "readme")
        #expect(results == [1])
        #expect(index.count == 1)
    }

    // MARK: - 3. trigram 匹配

    @Test("trigram 匹配")
    func trigramMatching() {
        var index = TrigramIndex()
        index.insert(name: "report.pdf", id: 10)

        // "por" and "ort" are trigrams inside "report.pdf" -> lowercased "report.pdf"
        #expect(index.search(substring: "port") == [10])
        #expect(index.search(substring: "repo") == [10])
        #expect(index.search(substring: "pdf") == [10])
    }

    // MARK: - 4. 长文件名匹配

    @Test("长文件名匹配 (>64 chars)")
    func longFilenameMatches() {
        var index = TrigramIndex()

        // 80-character filename — too long for FullSubstringMap, perfect for TrigramIndex
        let longName = String(repeating: "abcdefghij", count: 8) // "abcdefghij" repeated 8 times = 80 chars
        index.insert(name: longName, id: 42)

        #expect(index.search(substring: "abcdefghij") == [42])
        #expect(index.search(substring: "cdef") == [42])
        #expect(index.search(substring: "ghij") == [42])
        #expect(index.count == 1)
    }

    // MARK: - 5. 短查询匹配 (< 3 chars)

    @Test("短查询匹配 (< 3 chars)")
    func shortQuery() {
        var index = TrigramIndex()
        index.insert(name: "ab.txt", id: 1)
        index.insert(name: "cd.txt", id: 2)
        index.insert(name: "x.txt", id: 3)

        // 2-char query
        let abResults = index.search(substring: "ab")
        #expect(abResults == [1])

        // 1-char query
        let xResults = index.search(substring: "x")
        #expect(Set(xResults) == [1, 2, 3])
    }

    // MARK: - 6. 多文件交集

    @Test("多文件交集")
    func multiFileIntersection() {
        var index = TrigramIndex()
        index.insert(name: "report_2024.pdf", id: 1)
        index.insert(name: "report_2025.pdf", id: 2)
        index.insert(name: "summary.doc", id: 3)

        // "report" appears in ids 1 and 2
        let reportResults = index.search(substring: "report")
        #expect(Set(reportResults) == [1, 2])

        // "2024" only in id 1
        let y2024 = index.search(substring: "2024")
        #expect(y2024 == [1])

        // "summary" only in id 3
        let summaryResults = index.search(substring: "summary")
        #expect(summaryResults == [3])
    }

    // MARK: - 7. 无匹配返回空

    @Test("无匹配返回空")
    func noMatchReturnsEmpty() {
        var index = TrigramIndex()
        index.insert(name: "hello.txt", id: 1)

        #expect(index.search(substring: "xyz") == [])
        #expect(index.search(substring: "helloo") == [])
    }

    // MARK: - 8. 删除后不再匹配

    @Test("删除后不再匹配")
    func removeThenNotFound() {
        var index = TrigramIndex()
        index.insert(name: "delete_me.txt", id: 42)

        #expect(index.search(substring: "delete") == [42])

        index.remove(name: "delete_me.txt", id: 42)

        #expect(index.search(substring: "delete") == [])
        #expect(index.search(substring: "delete_me") == [])
        #expect(index.count == 0)
    }

    // MARK: - 9. 大小写不敏感

    @Test("大小写不敏感")
    func caseInsensitive() {
        var index = TrigramIndex()
        index.insert(name: "Report.PDF", id: 1)

        #expect(index.search(substring: "report.pdf") == [1])
        #expect(index.search(substring: "REPORT") == [1])
        #expect(index.search(substring: "pdf") == [1])
    }

    // MARK: - 10. Unicode trigram — CJK

    @Test("Unicode trigram — CJK 字符")
    func unicodeCJKTrigram() {
        var index = TrigramIndex()
        index.insert(name: "项目报告.pdf", id: 100)
        index.insert(name: "项目计划.pdf", id: 101)

        let xmResults = index.search(substring: "项目")
        #expect(Set(xmResults) == [100, 101])

        #expect(index.search(substring: "报告") == [100])
        #expect(index.search(substring: "计划") == [101])
    }

    // MARK: - 11. NFC 统一化

    @Test("NFC 统一化")
    func nfcNormalized() {
        var index = TrigramIndex()

        // "é" (e + combining acute accent, NFD form) — after NFC normalization becomes "é"
        let nfdName = "re\u{0301}sume\u{0301}.pdf"
        let nfcSubstring = "résumé"

        index.insert(name: nfdName, id: 1)

        let results = index.search(substring: nfcSubstring)
        #expect(results == [1])
    }

    // MARK: - 12. count 属性

    @Test("count 属性")
    func countProperty() {
        var index = TrigramIndex()
        #expect(index.count == 0)

        index.insert(name: "one.txt", id: 1)
        #expect(index.count == 1)

        index.insert(name: "two.txt", id: 2)
        #expect(index.count == 2)

        index.insert(name: "three.txt", id: 3)
        #expect(index.count == 3)

        index.remove(name: "one.txt", id: 1)
        #expect(index.count == 2)

        // Removing non-existent entry does not change count
        index.remove(name: "nonexistent.txt", id: 99)
        #expect(index.count == 2)
    }

    // MARK: - 13. 精确验证避免误匹配

    @Test("精确验证避免误匹配")
    func exactVerificationPreventsFalsePositives() {
        var index = TrigramIndex()

        // Insert names that share all trigrams with a query but don't actually
        // contain the query as a substring. Without verification, these would
        // be false positives.
        //
        // "abc" has trigrams: abc
        // "bcd" has trigrams: bcd
        // Together they cover the trigrams of "abcd" (abc, bcd) but neither
        // individually contains "abcd" as a substring.
        index.insert(name: "abc", id: 1)
        index.insert(name: "bcd", id: 2)
        index.insert(name: "abcd", id: 3)

        let results = index.search(substring: "abcd")
        // Only id 3 actually contains "abcd" as a substring
        #expect(results == [3])

        // "abc" should still match "abc" itself
        #expect(Set(index.search(substring: "abc")) == [1, 3])

        // "bcd" should still match "bcd" itself
        #expect(Set(index.search(substring: "bcd")) == [2, 3])
    }
}
