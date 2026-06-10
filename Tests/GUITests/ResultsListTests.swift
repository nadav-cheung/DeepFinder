import Testing
import Foundation
import DeepFinderIndex
import DeepFinderSearch
@testable import DeepFinderGUILib

// MARK: - ResultsListState Tests

@Suite("ResultsListState")
struct ResultsListTests {

    // MARK: - Helpers

    /// Create a fake SearchResult for testing.
    private func makeResult(id: UInt32, name: String = "test.txt") -> SearchResult {
        SearchResult(
            record: FileRecord(
                id: id,
                name: name,
                originalName: name,
                path: "/tmp/\(name)",
                parentPath: "/tmp",
                isDirectory: false,
                size: 100,
                createdAt: Date(),
                modifiedAt: Date(),
                extension: "txt"
            ),
            providerID: "test",
            score: 1.0,
            matchType: .substring
        )
    }

    /// Create an array of N fake results.
    private func makeResults(_ count: Int) -> [SearchResult] {
        (0..<UInt32(count)).map { makeResult(id: $0, name: "file\($0).txt") }
    }

    // MARK: - Test 1: Empty results shows friendly message

    @Test("Empty results shows friendly message")
    func emptyResultsShowsMessage() {
        let state = ResultsListState()
        #expect(state.isEmpty)
        #expect(state.statusText == "未找到匹配文件")
    }

    // MARK: - Test 2: Results displayed in LazyVStack (state tracks visible results)

    @Test("Results populated after setting results")
    func resultsDisplayed() {
        let state = ResultsListState()
        let results = makeResults(5)
        state.setResults(results)

        #expect(!state.isEmpty)
        #expect(state.visibleResults.count == 5)
        #expect(state.allResults.count == 5)
    }

    // MARK: - Test 3: Pagination — first 100 shown

    @Test("Pagination shows first 100 results")
    func paginationFirst100() {
        let state = ResultsListState()
        let results = makeResults(250)
        state.setResults(results)

        #expect(state.visibleResults.count == 100)
        #expect(state.allResults.count == 250)
        #expect(state.hasMoreResults)
    }

    // MARK: - Test 4: Load more increases visible count

    @Test("Load more increases visible count")
    func loadMoreIncreasesCount() {
        let state = ResultsListState()
        let results = makeResults(250)
        state.setResults(results)

        #expect(state.visibleResults.count == 100)

        state.loadMore()
        #expect(state.visibleResults.count == 200)

        state.loadMore()
        #expect(state.visibleResults.count == 250)
        #expect(!state.hasMoreResults)
    }

    // MARK: - Test 5: New query resets pagination

    @Test("New query resets pagination")
    func newQueryResetsPagination() {
        let state = ResultsListState()
        let results = makeResults(250)
        state.setResults(results)
        state.loadMore()
        #expect(state.visibleResults.count == 200)

        // New query with fewer results
        let newResults = makeResults(10)
        state.setResults(newResults)

        #expect(state.visibleResults.count == 10)
        #expect(!state.hasMoreResults)
    }

    // MARK: - Test 6: Max 10000 cap with message

    @Test("Max 10000 cap with message")
    func max10000Cap() {
        let state = ResultsListState()
        let results = makeResults(15000)
        state.setResults(results)

        // Only 10000 should be kept
        #expect(state.allResults.count == 10_000)
        #expect(state.isCapped)
        #expect(state.statusText.contains("结果过多"))
    }

    // MARK: - Test 7: Keyboard selection moves index

    @Test("Keyboard selection moves index")
    func keyboardSelectionMovesIndex() {
        let state = ResultsListState()
        let results = makeResults(10)
        state.setResults(results)

        #expect(state.selectedIndex == nil)

        state.moveSelection(down: true)
        #expect(state.selectedIndex == 0)

        state.moveSelection(down: true)
        #expect(state.selectedIndex == 1)

        state.moveSelection(down: false) // up
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Test 8: Selected index wraps at boundaries

    @Test("Selected index wraps at boundaries")
    func selectionWrapsAtBoundaries() {
        let state = ResultsListState()
        let results = makeResults(5)
        state.setResults(results)

        // At top, move up wraps to bottom
        state.moveSelection(down: true) // index 0
        state.moveSelection(down: false) // up from 0 -> wraps to last
        #expect(state.selectedIndex == 4)

        // At bottom, move down wraps to top
        state.moveSelection(down: true) // wraps to 0
        #expect(state.selectedIndex == 0)
    }
}
