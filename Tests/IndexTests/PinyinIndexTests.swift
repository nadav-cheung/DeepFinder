import Foundation
import Testing
@testable import DeepFinderIndex

@Suite("PinyinIndex")
struct PinyinIndexTests {

    // MARK: - 1. 空索引搜索返回空

    @Test("空索引搜索返回空")
    func emptyIndexReturnsEmpty() {
        let index = PinyinIndex()
        #expect(index.count == 0)
        #expect(index.search(pinyin: "anything") == [])
    }

    // MARK: - 2. 全拼搜索

    @Test("全拼搜索")
    func fullPinyinSearch() {
        var index = PinyinIndex()
        // "报告" -> CFStringTokenizer tokenizes -> CFStringTransform -> "baogao"
        index.insert(name: "季度报告.pdf", id: 1)

        let results = index.search(pinyin: "baogao")
        #expect(results.contains(1))
    }

    // MARK: - 3. 首字母搜索

    @Test("首字母搜索")
    func firstLetterSearch() {
        var index = PinyinIndex()
        // "季度报告" -> tokens ["季度", "报告"] -> pinyin ["jidu", "baogao"]
        // first letters: "j", "d", "b", "g" -> concatenated per token: "jd", "bg"
        index.insert(name: "季度报告.pdf", id: 1)

        // Search by first-letter abbreviation "jdbg" (jd + bg)
        let results = index.search(pinyin: "jdbg")
        #expect(results.contains(1))
    }

    // MARK: - 4. 部分拼音匹配

    @Test("部分拼音匹配")
    func partialPinyinMatch() {
        var index = PinyinIndex()
        index.insert(name: "季度报告.pdf", id: 1)

        // "bao" is a prefix of "baogao" — should match via full pinyin trie prefix search
        let results = index.search(pinyin: "bao")
        #expect(results.contains(1))
    }

    // MARK: - 5. 非中文字符被跳过

    @Test("非中文字符被跳过")
    func nonChineseCharsSkipped() {
        var index = PinyinIndex()
        // Pure ASCII name — no Chinese tokens, nothing indexed
        index.insert(name: "readme.txt", id: 1)

        #expect(index.search(pinyin: "readme") == [])
        #expect(index.count == 0)
    }

    // MARK: - 6. 混合中英文文件名

    @Test("混合中英文文件名")
    func mixedChineseEnglish() {
        var index = PinyinIndex()
        // "项目README.md" -> Chinese token "项目" -> pinyin "xiangmu"
        index.insert(name: "项目README.md", id: 1)

        let results = index.search(pinyin: "xiangmu")
        #expect(results.contains(1))

        // First letter of "xiangmu" is "x" -> "xm"
        let flResults = index.search(pinyin: "xm")
        #expect(flResults.contains(1))
    }

    // MARK: - 7. 多文件共享拼音

    @Test("多文件共享拼音")
    func multipleFilesSharedPinyin() {
        var index = PinyinIndex()
        // Both contain "项目"
        index.insert(name: "项目报告.pdf", id: 1)
        index.insert(name: "项目计划.doc", id: 2)

        let results = index.search(pinyin: "xiangmu")
        #expect(Set(results) == [1, 2])

        let flResults = index.search(pinyin: "xm")
        #expect(Set(flResults) == [1, 2])
    }

    // MARK: - 8. 删除后不再可搜索

    @Test("删除后不再可搜索")
    func removeThenNotFound() {
        var index = PinyinIndex()
        index.insert(name: "季度报告.pdf", id: 1)
        #expect(index.count == 1)

        index.remove(name: "季度报告.pdf", id: 1)
        #expect(index.count == 0)

        #expect(index.search(pinyin: "baogao") == [])
        #expect(index.search(pinyin: "jdbg") == [])
    }

    // MARK: - 9. 全拼和首字母都能搜到

    @Test("全拼和首字母都能搜到")
    func bothFullAndAbbreviationFind() {
        var index = PinyinIndex()
        index.insert(name: "测试.txt", id: 42)

        // "测试" -> "ceshi" in full pinyin, "cs" as first letters
        let fullResults = index.search(pinyin: "ceshi")
        #expect(fullResults.contains(42))

        let flResults = index.search(pinyin: "cs")
        #expect(flResults.contains(42))
    }

    // MARK: - 10. 繁体中文

    @Test("繁体中文")
    func traditionalChinese() {
        var index = PinyinIndex()
        // "報告" (traditional) should also be tokenizable and convertible to pinyin
        index.insert(name: "季度報告.pdf", id: 1)

        let results = index.search(pinyin: "baogao")
        #expect(results.contains(1))
    }

    // MARK: - 11. 带声调的拼音被去除

    @Test("带声调的拼音被去除")
    func toneMarksStripped() {
        var index = PinyinIndex()
        index.insert(name: "测试.txt", id: 1)

        // CFStringTransform with kCFStringTransformToLatin produces pinyin with tone marks
        // like "cè shì". Our implementation must strip diacritics so user can type "ceshi".
        // This test verifies that the implementation strips tones correctly.
        let results = index.search(pinyin: "ceshi")
        #expect(results.contains(1))
    }

    // MARK: - 12. NFC 统一化

    @Test("NFC 统一化")
    func nfcNormalized() {
        var index = PinyinIndex()

        // NFD form of a Chinese name — should be NFC-normalized before processing
        // Most Chinese characters are the same in NFC/NFD, but the normalization
        // should still be applied consistently.
        let name = "报告.pdf"
        index.insert(name: name, id: 1)

        // Same name, already NFC — should be dedupable
        let results = index.search(pinyin: "baogao")
        #expect(results.contains(1))
    }

    // MARK: - 13. 英文文件名无拼音索引

    @Test("英文文件名无拼音索引")
    func englishOnlyNoPinyin() {
        var index = PinyinIndex()
        index.insert(name: "Report.pdf", id: 1)
        index.insert(name: "README.md", id: 2)

        // No Chinese characters -> no pinyin entries
        #expect(index.count == 0)

        // Inserting a Chinese name alongside should only count that one
        index.insert(name: "报告.pdf", id: 3)
        #expect(index.count == 1)
    }

    // MARK: - 14. count 属性

    @Test("count 属性")
    func countProperty() {
        var index = PinyinIndex()
        #expect(index.count == 0)

        index.insert(name: "报告.pdf", id: 1)
        #expect(index.count == 1)

        index.insert(name: "项目.doc", id: 2)
        #expect(index.count == 2)

        index.insert(name: "readme.txt", id: 3)  // English, not counted
        #expect(index.count == 2)

        index.remove(name: "报告.pdf", id: 1)
        #expect(index.count == 1)

        index.remove(name: "readme.txt", id: 3)  // Was never counted
        #expect(index.count == 1)
    }
}
