import Foundation
import Testing
@testable import DeepFinder

@Suite("Trie")
struct TrieTests {

    // MARK: - Empty Trie

    @Test("空 Trie 搜索返回空")
    func emptyTrieSearchReturnsEmpty() {
        let trie = Trie<UnicodeScalar, UInt32>()
        let results = trie.search(prefix: Array("a".unicodeScalars))
        #expect(results.isEmpty)
    }

    // MARK: - Insert & Prefix Search

    @Test("插入后可按前缀搜索")
    func insertThenPrefixSearch() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("hello".unicodeScalars), value: 1)

        let results = trie.search(prefix: Array("hel".unicodeScalars))
        #expect(results == [1])
    }

    @Test("精确匹配")
    func exactMatch() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("hello".unicodeScalars), value: 42)

        let results = trie.search(prefix: Array("hello".unicodeScalars))
        #expect(results == [42])
    }

    @Test("前缀匹配返回多个结果")
    func prefixMatchReturnsMultiple() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("apple".unicodeScalars), value: 1)
        trie.insert(Array("application".unicodeScalars), value: 2)
        trie.insert(Array("apply".unicodeScalars), value: 3)

        let results = trie.search(prefix: Array("app".unicodeScalars))
        #expect(results.sorted() == [1, 2, 3])
    }

    @Test("不同前缀不匹配")
    func differentPrefixNoMatch() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("hello".unicodeScalars), value: 1)

        let results = trie.search(prefix: Array("world".unicodeScalars))
        #expect(results.isEmpty)
    }

    @Test("空字符串前缀返回所有")
    func emptyPrefixReturnsAll() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("cat".unicodeScalars), value: 10)
        trie.insert(Array("dog".unicodeScalars), value: 20)
        trie.insert(Array("bird".unicodeScalars), value: 30)

        let results = trie.search(prefix: [])
        #expect(results.sorted() == [10, 20, 30])
    }

    // MARK: - Unicode

    @Test("Unicode 前缀匹配")
    func unicodePrefixMatch() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("文件系统".unicodeScalars), value: 1)
        trie.insert(Array("文件夹".unicodeScalars), value: 2)
        trie.insert(Array("文档".unicodeScalars), value: 3)

        let results = trie.search(prefix: Array("文".unicodeScalars))
        #expect(results.sorted() == [1, 2, 3])
    }

    @Test("Emoji 前缀匹配")
    func emojiPrefixMatch() {
        var trie = Trie<UnicodeScalar, UInt32>()
        // "🎉party" — 🎉 is a single Unicode scalar (U+1F389)
        trie.insert(Array("🎉party".unicodeScalars), value: 100)
        trie.insert(Array("🎉cake".unicodeScalars), value: 200)

        let results = trie.search(prefix: Array("🎉".unicodeScalars))
        #expect(results.sorted() == [100, 200])
    }

    @Test("NFC 统一化")
    func nfcNormalization() {
        var trie = Trie<UnicodeScalar, UInt32>()
        // "café" precomposed (NFC): c-a-f-\u{00E9}
        let nfcInput = "caf\u{00E9}"
        // "café" decomposed (NFD): c-a-f-\u{0301}-e  — but NFC-normalized becomes same as above
        let nfdInput = "cafe\u{0301}"

        let normalized = nfdInput.precomposedStringWithCanonicalMapping
        trie.insert(Array(normalized.unicodeScalars), value: 55)

        // Searching with NFC input should match
        let results = trie.search(prefix: Array(nfcInput.unicodeScalars))
        #expect(results == [55])
    }

    // MARK: - Delete

    @Test("删除后不再可搜索")
    func deleteRemovesEntry() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("hello".unicodeScalars), value: 1)

        let removed = trie.remove(Array("hello".unicodeScalars))
        #expect(removed == 1)

        let results = trie.search(prefix: Array("hello".unicodeScalars))
        #expect(results.isEmpty)
    }

    @Test("删除不影响其他条目")
    func deleteDoesNotAffectOthers() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("hello".unicodeScalars), value: 1)
        trie.insert(Array("help".unicodeScalars), value: 2)
        trie.insert(Array("world".unicodeScalars), value: 3)

        let removed = trie.remove(Array("hello".unicodeScalars))
        #expect(removed == 1)

        let helResults = trie.search(prefix: Array("hel".unicodeScalars))
        #expect(helResults == [2])

        let worldResults = trie.search(prefix: Array("world".unicodeScalars))
        #expect(worldResults == [3])
    }

    // MARK: - Duplicate Insert

    @Test("重复插入更新值")
    func duplicateInsertUpdatesValue() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("test".unicodeScalars), value: 10)
        trie.insert(Array("test".unicodeScalars), value: 20)

        let results = trie.search(prefix: Array("test".unicodeScalars))
        #expect(results == [20])
        #expect(trie.count == 1)
    }

    // MARK: - count & isEmpty

    @Test("count 属性正确")
    func countProperty() {
        var trie = Trie<UnicodeScalar, UInt32>()
        #expect(trie.count == 0)

        trie.insert(Array("a".unicodeScalars), value: 1)
        #expect(trie.count == 1)

        trie.insert(Array("ab".unicodeScalars), value: 2)
        #expect(trie.count == 2)

        trie.insert(Array("abc".unicodeScalars), value: 3)
        #expect(trie.count == 3)

        _ = trie.remove(Array("ab".unicodeScalars))
        #expect(trie.count == 2)
    }

    @Test("isEmpty 属性正确")
    func isEmptyProperty() {
        var trie = Trie<UnicodeScalar, UInt32>()
        #expect(trie.isEmpty)

        trie.insert(Array("x".unicodeScalars), value: 1)
        #expect(!trie.isEmpty)

        _ = trie.remove(Array("x".unicodeScalars))
        #expect(trie.isEmpty)
    }

    // MARK: - Exact-Key Lookup (get)

    @Test("get 返回精确键的值")
    func getReturnsExactKeyValue() {
        var trie = Trie<UnicodeScalar, Set<UInt32>>()
        trie.insert(Array("ab".unicodeScalars), value: [1, 2])
        trie.insert(Array("a".unicodeScalars), value: [3, 4])

        #expect(trie.get(key: Array("ab".unicodeScalars)) == [1, 2])
        #expect(trie.get(key: Array("a".unicodeScalars)) == [3, 4])
        #expect(trie.get(key: Array("abc".unicodeScalars)) == nil)
    }

    // MARK: - Copy-on-Write Value Semantics

    @Test("复制 Trie 后修改副本不影响原始")
    func copyOnWriteMutatingCopyDoesNotAffectOriginal() {
        var original = Trie<UnicodeScalar, UInt32>()
        original.insert(Array("hello".unicodeScalars), value: 1)
        original.insert(Array("help".unicodeScalars), value: 2)

        var copy = original
        copy.insert(Array("helm".unicodeScalars), value: 3)
        _ = copy.remove(Array("hello".unicodeScalars))

        // Original is unchanged
        let originalResults = original.search(prefix: Array("hel".unicodeScalars))
        #expect(originalResults.sorted() == [1, 2])
        #expect(original.count == 2)

        // Copy has the mutations: "helm"(3) added, "hello"(1) removed, "help"(2) kept
        let copyResults = copy.search(prefix: Array("hel".unicodeScalars))
        #expect(copyResults.sorted() == [2, 3])
        #expect(copy.count == 2)
    }

    @Test("复制 Trie 后不修改则共享节点")
    func copyOnWriteReadsShareStorage() {
        var trie = Trie<UnicodeScalar, UInt32>()
        trie.insert(Array("abc".unicodeScalars), value: 10)

        let copy = trie
        // Both should return the same results without any mutation
        #expect(trie.search(prefix: Array("a".unicodeScalars)) == [10])
        #expect(copy.search(prefix: Array("a".unicodeScalars)) == [10])
    }

    @Test("get 区分前缀关系：删除长键不影响短键")
    func getDistinguishesPrefixRelationships() {
        var trie = Trie<UnicodeScalar, Set<UInt32>>()
        let abScalars = Array("ab".unicodeScalars)
        let aScalars = Array("a".unicodeScalars)

        trie.insert(abScalars, value: [10])
        trie.insert(aScalars, value: [20])

        // Remove "ab" should NOT affect "a"
        _ = trie.remove(abScalars)
        #expect(trie.get(key: aScalars) == [20])
        #expect(trie.get(key: abScalars) == nil)
    }
}
