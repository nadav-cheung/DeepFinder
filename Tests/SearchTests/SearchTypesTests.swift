import Testing
import Foundation

import DeepFinderAI
import DeepFinderPersist
import DeepFinderIndex
@testable import DeepFinderSearch

@Suite("SearchTypes")
struct SearchTypesTests {

    // MARK: - SearchQuery

    @Test("SearchQuery normalizes to NFC + lowercased")
    func testSearchQueryNormalization() {
        let query = SearchQuery("Hello World")
        #expect(query.rawQuery == "Hello World")
        #expect(query.normalizedQuery == "hello world")
    }

    @Test("SearchQuery preserves original rawQuery")
    func testSearchQueryPreservesOriginal() {
        let input = "FooBar_BAZ123"
        let query = SearchQuery(input)
        #expect(query.rawQuery == input)
    }

    @Test("SearchQuery handles empty string gracefully")
    func testSearchQueryEmptyString() {
        let query = SearchQuery("")
        #expect(query.rawQuery == "")
        #expect(query.normalizedQuery == "")
    }

    @Test("SearchQuery normalizes Unicode combining characters (NFC)")
    func testSearchQueryUnicodeNormalization() {
        // e + combining acute accent (NFD) should become precomposed é (NFC)
        let nfdInput = "e\u{0301}tude"
        let query = SearchQuery(nfdInput)
        // NFC form of é is the single character U+00E9
        let expectedNFC = "\u{00E9}tude"
        #expect(query.normalizedQuery == expectedNFC.lowercased())
    }

    // MARK: - MatchType

    @Test("MatchType ordering: exact < prefix < pinyin < substring")
    func testMatchTypeOrdering() {
        #expect(MatchType.exact < MatchType.prefix)
        #expect(MatchType.prefix < MatchType.pinyin)
        #expect(MatchType.pinyin < MatchType.substring)
    }

    @Test("MatchType is Comparable and can be sorted")
    func testMatchTypeComparable() {
        let unsorted: [MatchType] = [.substring, .exact, .pinyin, .prefix]
        let sorted = unsorted.sorted()
        #expect(sorted == [.exact, .prefix, .pinyin, .substring])
    }

    // MARK: - SearchResult

    @Test("SearchResult equality is by record.id only")
    func testSearchResultEquatability() {
        let record = FileRecord(
            id: 42,
            name: "test",
            originalName: "Test",
            path: "/tmp/test",
            parentPath: "/tmp",
            isDirectory: false,
            size: 100,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: nil
        )
        let result1 = SearchResult(
            record: record,
            providerID: "provider-a",
            score: 0.9,
            matchType: .exact
        )
        let result2 = SearchResult(
            record: record,
            providerID: "provider-b",
            score: 0.5,
            matchType: .substring
        )
        // Same record.id => equal regardless of score/provider/matchType
        #expect(result1 == result2)
    }

    @Test("SearchResult with different record.id is not equal")
    func testSearchResultDifferentRecords() {
        let record1 = FileRecord(
            id: 1,
            name: "alpha",
            originalName: "alpha",
            path: "/a",
            parentPath: "/",
            isDirectory: false,
            size: 10,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: nil
        )
        let record2 = FileRecord(
            id: 2,
            name: "beta",
            originalName: "beta",
            path: "/b",
            parentPath: "/",
            isDirectory: false,
            size: 20,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: nil
        )
        let result1 = SearchResult(
            record: record1,
            providerID: "same-provider",
            score: 1.0,
            matchType: .exact
        )
        let result2 = SearchResult(
            record: record2,
            providerID: "same-provider",
            score: 1.0,
            matchType: .exact
        )
        #expect(result1 != result2)
    }

    @Test("SearchResult score is in 0.0...1.0 range")
    func testSearchResultScoreRange() {
        let record = FileRecord(
            id: 1,
            name: "file",
            originalName: "file",
            path: "/file",
            parentPath: "/",
            isDirectory: false,
            size: 0,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: nil
        )
        let zeroResult = SearchResult(
            record: record,
            providerID: "p",
            score: 0.0,
            matchType: .substring
        )
        let oneResult = SearchResult(
            record: record,
            providerID: "p",
            score: 1.0,
            matchType: .exact
        )
        #expect(zeroResult.score >= 0.0)
        #expect(oneResult.score <= 1.0)
    }
}
