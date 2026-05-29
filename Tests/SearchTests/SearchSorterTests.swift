import XCTest
@testable import DeepFinder

final class SearchSorterTests: XCTestCase {

    // MARK: - Helpers

    private func makeRecord(
        id: UInt32,
        name: String,
        path: String,
        size: Int64 = 0,
        modifiedAt: Date = Date()
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: path,
            parentPath: (path as NSString).deletingLastPathComponent,
            isDirectory: false,
            size: size,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            extension: (name as NSString).pathExtension.isEmpty
                ? nil
                : (name as NSString).pathExtension
        )
    }

    private func makeResult(
        id: UInt32,
        name: String,
        path: String,
        size: Int64 = 0,
        modifiedAt: Date = Date(),
        matchType: MatchType = .exact
    ) -> SearchResult {
        SearchResult(
            record: makeRecord(id: id, name: name, path: path, size: size, modifiedAt: modifiedAt),
            providerID: "test",
            score: 1.0,
            matchType: matchType
        )
    }

    // MARK: - Relevance sort

    func testRelevanceSortExactBeforePrefix() {
        let exact = makeResult(id: 2, name: "test.txt", path: "/a/test.txt", matchType: .exact)
        let prefix = makeResult(id: 1, name: "testing.txt", path: "/a/testing.txt", matchType: .prefix)

        let sorted = SearchSorter.sort([prefix, exact], by: .relevance)
        XCTAssertEqual(sorted[0].record.id, exact.record.id)
        XCTAssertEqual(sorted[1].record.id, prefix.record.id)
    }

    func testRelevanceSortPrefixBeforeSubstring() {
        let prefix = makeResult(id: 1, name: "test.txt", path: "/a/test.txt", matchType: .prefix)
        let substring = makeResult(id: 2, name: "attest.txt", path: "/a/attest.txt", matchType: .substring)

        let sorted = SearchSorter.sort([substring, prefix], by: .relevance)
        XCTAssertEqual(sorted[0].record.id, prefix.record.id)
        XCTAssertEqual(sorted[1].record.id, substring.record.id)
    }

    func testRelevanceSortShorterNameFirst() {
        let short = makeResult(id: 2, name: "a.txt", path: "/a/a.txt", matchType: .substring)
        let long = makeResult(id: 1, name: "abc.txt", path: "/a/abc.txt", matchType: .substring)

        let sorted = SearchSorter.sort([long, short], by: .relevance)
        XCTAssertEqual(sorted[0].record.id, short.record.id)
        XCTAssertEqual(sorted[1].record.id, long.record.id)
    }

    func testRelevanceSortNewerDateFirst() {
        let newer = makeResult(id: 2, name: "same.txt", path: "/a/same.txt", modifiedAt: Date(timeIntervalSince1970: 200), matchType: .substring)
        let older = makeResult(id: 1, name: "same.txt", path: "/a/same.txt", modifiedAt: Date(timeIntervalSince1970: 100), matchType: .substring)

        let sorted = SearchSorter.sort([older, newer], by: .relevance)
        XCTAssertEqual(sorted[0].record.id, newer.record.id)
        XCTAssertEqual(sorted[1].record.id, older.record.id)
    }

    func testRelevanceSortShallowerPathFirst() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let shallow = makeResult(id: 2, name: "x.txt", path: "/a/x.txt", modifiedAt: fixedDate, matchType: .substring)
        let deep = makeResult(id: 1, name: "x.txt", path: "/a/b/c/x.txt", modifiedAt: fixedDate, matchType: .substring)

        let sorted = SearchSorter.sort([deep, shallow], by: .relevance)
        XCTAssertEqual(sorted[0].record.id, shallow.record.id)
        XCTAssertEqual(sorted[1].record.id, deep.record.id)
    }

    func testRelevanceSortIDTiebreak() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let low = makeResult(id: 5, name: "x.txt", path: "/a/x.txt", modifiedAt: fixedDate, matchType: .substring)
        let high = makeResult(id: 10, name: "x.txt", path: "/a/x.txt", modifiedAt: fixedDate, matchType: .substring)

        let sorted = SearchSorter.sort([high, low], by: .relevance)
        XCTAssertEqual(sorted[0].record.id, low.record.id)
        XCTAssertEqual(sorted[1].record.id, high.record.id)
    }

    // MARK: - Name sort

    func testNameSortUsesLocalizedCompare() {
        let results = [
            makeResult(id: 1, name: "c.txt", path: "/c.txt"),
            makeResult(id: 2, name: "a.txt", path: "/a.txt"),
            makeResult(id: 3, name: "b.txt", path: "/b.txt"),
        ]

        let sorted = SearchSorter.sort(results, by: .name)
        XCTAssertEqual(sorted[0].record.name, "a.txt")
        XCTAssertEqual(sorted[1].record.name, "b.txt")
        XCTAssertEqual(sorted[2].record.name, "c.txt")
    }

    // MARK: - Date sort

    func testDateSortDescending() {
        let old = makeResult(id: 1, name: "old.txt", path: "/old.txt", modifiedAt: Date(timeIntervalSince1970: 100))
        let mid = makeResult(id: 2, name: "mid.txt", path: "/mid.txt", modifiedAt: Date(timeIntervalSince1970: 200))
        let recent = makeResult(id: 3, name: "new.txt", path: "/new.txt", modifiedAt: Date(timeIntervalSince1970: 300))

        let sorted = SearchSorter.sort([old, mid, recent], by: .date)
        XCTAssertEqual(sorted[0].record.id, recent.record.id)
        XCTAssertEqual(sorted[1].record.id, mid.record.id)
        XCTAssertEqual(sorted[2].record.id, old.record.id)
    }

    // MARK: - Size sort

    func testSizeSortDescending() {
        let small = makeResult(id: 1, name: "s.txt", path: "/s.txt", size: 100)
        let medium = makeResult(id: 2, name: "m.txt", path: "/m.txt", size: 500)
        let large = makeResult(id: 3, name: "l.txt", path: "/l.txt", size: 1000)

        let sorted = SearchSorter.sort([small, medium, large], by: .size)
        XCTAssertEqual(sorted[0].record.id, large.record.id)
        XCTAssertEqual(sorted[1].record.id, medium.record.id)
        XCTAssertEqual(sorted[2].record.id, small.record.id)
    }

    // MARK: - Edge cases

    func testEmptyInputReturnsEmpty() {
        let sorted = SearchSorter.sort([], by: .relevance)
        XCTAssertTrue(sorted.isEmpty)
    }

    func testSingleResultUnchanged() {
        let result = makeResult(id: 42, name: "only.txt", path: "/only.txt", matchType: .exact)
        let sorted = SearchSorter.sort([result], by: .relevance)
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted[0].record.id, 42)
    }

    // MARK: - pathDepth helper

    func testPathDepthRoot() {
        XCTAssertEqual(SearchSorter.pathDepth("/file.txt"), 1)
    }

    func testPathDepthNested() {
        XCTAssertEqual(SearchSorter.pathDepth("/a/b/c/file.txt"), 4)
    }

    func testPathDepthEmpty() {
        XCTAssertEqual(SearchSorter.pathDepth(""), 0)
    }
}
