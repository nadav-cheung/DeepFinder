import XCTest
@testable import DeepFinder

final class NaturalSortTests: XCTestCase {

    // MARK: - naturalCompare

    func testNaturalSortFileSequence() {
        // file1 < file2 < file10 (not lexicographic "file1" < "file10" < "file2")
        XCTAssertTrue(SearchSorter.naturalCompare("file1", "file2"))
        XCTAssertTrue(SearchSorter.naturalCompare("file2", "file10"))
        XCTAssertFalse(SearchSorter.naturalCompare("file10", "file2"))
    }

    func testNaturalSortVersionNumbers() {
        // v2 < v10 < v11
        XCTAssertTrue(SearchSorter.naturalCompare("v2", "v10"))
        XCTAssertTrue(SearchSorter.naturalCompare("v10", "v11"))
        XCTAssertFalse(SearchSorter.naturalCompare("v11", "v10"))
    }

    func testNaturalSortMixedWithExtension() {
        // "img1.png" < "img10.png"
        XCTAssertTrue(SearchSorter.naturalCompare("img1.png", "img10.png"))
        XCTAssertFalse(SearchSorter.naturalCompare("img10.png", "img1.png"))
    }

    func testNaturalSortPureNumbers() {
        // 1 < 2 < 10 < 100
        XCTAssertTrue(SearchSorter.naturalCompare("1", "2"))
        XCTAssertTrue(SearchSorter.naturalCompare("2", "10"))
        XCTAssertTrue(SearchSorter.naturalCompare("10", "100"))
        XCTAssertFalse(SearchSorter.naturalCompare("100", "10"))
    }

    func testNaturalSortEqualStrings() {
        // Equal strings: not less than itself
        XCTAssertFalse(SearchSorter.naturalCompare("file10", "file10"))
        XCTAssertFalse(SearchSorter.naturalCompare("abc", "abc"))
        XCTAssertFalse(SearchSorter.naturalCompare("123", "123"))
    }

    func testNaturalSortEmptyStrings() {
        // Empty < non-empty
        XCTAssertTrue(SearchSorter.naturalCompare("", "a"))
        XCTAssertFalse(SearchSorter.naturalCompare("a", ""))
        XCTAssertFalse(SearchSorter.naturalCompare("", ""))
    }

    func testNaturalSortNonNumericFallbackToLexicographic() {
        // Purely non-numeric strings use lexicographic comparison
        XCTAssertTrue(SearchSorter.naturalCompare("apple", "banana"))
        XCTAssertFalse(SearchSorter.naturalCompare("banana", "apple"))
        // Mixed: same prefix, same digit, different suffix
        XCTAssertTrue(SearchSorter.naturalCompare("file1a", "file1b"))
        XCTAssertFalse(SearchSorter.naturalCompare("file1b", "file1a"))
    }

    func testNaturalSortUnicodeAware() {
        // Unicode characters compared correctly
        XCTAssertTrue(SearchSorter.naturalCompare("a", "b"))
        // NFC-normalized comparison: composed é vs decomposed e + combining acute
        let composed = "f\u{00E9}1"      // é as single scalar
        let decomposed = "fe\u{0301}1"   // e + combining acute accent
        // After NFC normalization both should be equal
        XCTAssertFalse(SearchSorter.naturalCompare(composed, decomposed))
        XCTAssertFalse(SearchSorter.naturalCompare(decomposed, composed))
    }

    // MARK: - SortCriterion.natural

    func testNaturalSortCriterion() {
        let helper = SortTestHelper()
        let results = [
            helper.makeResult(id: 4, name: "file10.txt", path: "/file10.txt"),
            helper.makeResult(id: 1, name: "file1.txt", path: "/file1.txt"),
            helper.makeResult(id: 3, name: "file2.txt", path: "/file2.txt"),
            helper.makeResult(id: 2, name: "file100.txt", path: "/file100.txt"),
        ]

        let sorted = SearchSorter.sort(results, by: .natural)
        XCTAssertEqual(sorted[0].record.name, "file1.txt")
        XCTAssertEqual(sorted[1].record.name, "file2.txt")
        XCTAssertEqual(sorted[2].record.name, "file10.txt")
        XCTAssertEqual(sorted[3].record.name, "file100.txt")
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
