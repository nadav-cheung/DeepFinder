import Testing
import Foundation
@testable import DeepFinder

struct NaturalSortTests {

    // MARK: - naturalCompare

    @Test func naturalSortFileSequence() {
        // file1 < file2 < file10 (not lexicographic "file1" < "file10" < "file2")
        #expect(SearchSorter.naturalCompare("file1", "file2"))
        #expect(SearchSorter.naturalCompare("file2", "file10"))
        #expect(!SearchSorter.naturalCompare("file10", "file2"))
    }

    @Test func naturalSortVersionNumbers() {
        // v2 < v10 < v11
        #expect(SearchSorter.naturalCompare("v2", "v10"))
        #expect(SearchSorter.naturalCompare("v10", "v11"))
        #expect(!SearchSorter.naturalCompare("v11", "v10"))
    }

    @Test func naturalSortMixedWithExtension() {
        // "img1.png" < "img10.png"
        #expect(SearchSorter.naturalCompare("img1.png", "img10.png"))
        #expect(!SearchSorter.naturalCompare("img10.png", "img1.png"))
    }

    @Test func naturalSortPureNumbers() {
        // 1 < 2 < 10 < 100
        #expect(SearchSorter.naturalCompare("1", "2"))
        #expect(SearchSorter.naturalCompare("2", "10"))
        #expect(SearchSorter.naturalCompare("10", "100"))
        #expect(!SearchSorter.naturalCompare("100", "10"))
    }

    @Test func naturalSortEqualStrings() {
        // Equal strings: not less than itself
        #expect(!SearchSorter.naturalCompare("file10", "file10"))
        #expect(!SearchSorter.naturalCompare("abc", "abc"))
        #expect(!SearchSorter.naturalCompare("123", "123"))
    }

    @Test func naturalSortEmptyStrings() {
        // Empty < non-empty
        #expect(SearchSorter.naturalCompare("", "a"))
        #expect(!SearchSorter.naturalCompare("a", ""))
        #expect(!SearchSorter.naturalCompare("", ""))
    }

    @Test func naturalSortNonNumericFallbackToLexicographic() {
        // Purely non-numeric strings use lexicographic comparison
        #expect(SearchSorter.naturalCompare("apple", "banana"))
        #expect(!SearchSorter.naturalCompare("banana", "apple"))
        // Mixed: same prefix, same digit, different suffix
        #expect(SearchSorter.naturalCompare("file1a", "file1b"))
        #expect(!SearchSorter.naturalCompare("file1b", "file1a"))
    }

    @Test func naturalSortUnicodeAware() {
        // Unicode characters compared correctly
        #expect(SearchSorter.naturalCompare("a", "b"))
        // NFC-normalized comparison: composed e vs decomposed e + combining acute
        let composed = "f\u{00E9}1"      // e as single scalar
        let decomposed = "fe\u{0301}1"   // e + combining acute accent
        // After NFC normalization both should be equal
        #expect(!SearchSorter.naturalCompare(composed, decomposed))
        #expect(!SearchSorter.naturalCompare(decomposed, composed))
    }

    @Test func naturalSortUnicodeSuperscriptDigitsNoCrash() {
        // Unicode superscript digits (U+00B2, U+00B3, U+00B9) have isNumber == true
        // but wholeNumberValue returns nil. Must not trap on force-unwrap.
        // "file\u{00B2}" contains a superscript 2 that isNumber but has no wholeNumberValue.
        // The comparator should treat the superscript as a non-digit segment and not crash.
        #expect(!SearchSorter.naturalCompare("file\u{00B2}", "file\u{00B2}"))
        #expect(SearchSorter.naturalCompare("file\u{00B2}", "file\u{00B3}"))
        // Mixed: regular digits followed by a superscript — should not crash
        #expect(SearchSorter.naturalCompare("file1\u{00B2}", "file2\u{00B3}"))
    }

    // MARK: - SortCriterion.natural

    @Test func naturalSortCriterion() {
        let helper = SortTestHelper()
        let results = [
            helper.makeResult(id: 4, name: "file10.txt", path: "/file10.txt"),
            helper.makeResult(id: 1, name: "file1.txt", path: "/file1.txt"),
            helper.makeResult(id: 3, name: "file2.txt", path: "/file2.txt"),
            helper.makeResult(id: 2, name: "file100.txt", path: "/file100.txt"),
        ]

        let sorted = SearchSorter.sort(results, by: .natural)
        #expect(sorted[0].record.name == "file1.txt")
        #expect(sorted[1].record.name == "file2.txt")
        #expect(sorted[2].record.name == "file10.txt")
        #expect(sorted[3].record.name == "file100.txt")
    }
}

// MARK: - Test helper (avoids duplicating makeResult in every test file)

private final class SortTestHelper {
    func makeResult(
        id: UInt32,
        name: String,
        path: String,
        matchType: MatchType = .exact
    ) -> SearchResult {
        let record = FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: path,
            parentPath: (path as NSString).deletingLastPathComponent,
            isDirectory: false,
            size: 0,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: (name as NSString).pathExtension.isEmpty
                ? nil
                : (name as NSString).pathExtension
        )
        return SearchResult(record: record, providerID: "test", score: 1.0, matchType: matchType)
    }
}
