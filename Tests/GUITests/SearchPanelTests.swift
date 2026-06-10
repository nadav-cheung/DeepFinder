import Testing
import Foundation
import AppKit
@testable import DeepFinder

@Suite("SearchPanel")
struct SearchPanelTests {

    // MARK: - Helpers

    private func makeRecord(id: UInt32, name: String, path: String) -> FileRecord {
        FileRecord(
            id: id,
            name: name.lowercased(),
            originalName: name,
            path: path,
            parentPath: (path as NSString).deletingLastPathComponent,
            isDirectory: false,
            size: 1024,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: (name as NSString).pathExtension.isEmpty
                ? nil
                : (name as NSString).pathExtension
        )
    }

    // MARK: - 1. ViewModel search text updates

    @Test("ViewModel search text updates via published property")
    func testSearchTextUpdates() async {
        let mock = MockGUIIPCClient(response: .results([], queryID: "q1"))
        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            viewModel.searchText = "report"
            #expect(viewModel.searchText == "report")

            viewModel.searchText = ""
            #expect(viewModel.searchText == "")
        }
    }

    // MARK: - 2. ViewModel triggers IPC query

    @Test("ViewModel search() sends IPC query request")
    func testSearchTriggersIPCQuery() async throws {
        let mock = MockGUIIPCClient(response: .results([], queryID: "q1"))
        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            viewModel.searchText = "hello"
        }
        await viewModel.search()

        let lastReq = await mock.lastRequest
        #expect(lastReq != nil)
        if case .query(let query, _) = lastReq! {
            #expect(query == "hello")
        } else {
            Issue.record("Expected .query request, got \(lastReq!)")
        }
    }

    // MARK: - 3. ViewModel stores results

    @Test("ViewModel stores search results from IPC response")
    func testViewModelStoresResults() async throws {
        let r1 = makeRecord(id: 1, name: "report.pdf", path: "/tmp/report.pdf")
        let r2 = makeRecord(id: 2, name: "report.txt", path: "/tmp/report.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let s2 = SearchResult(record: r2, providerID: "test", score: 0.8, matchType: .substring)
        let mock = MockGUIIPCClient(response: .results([s1, s2], queryID: "q1"))

        let viewModel = await SearchViewModel(ipcClient: mock)
        await MainActor.run {
            viewModel.searchText = "report"
        }
        await viewModel.search()

        let results = await viewModel.results
        #expect(results.count == 2)
        #expect(results[0].record.originalName == "report.pdf")
        #expect(results[1].record.originalName == "report.txt")
    }

    // MARK: - 4. Selected index tracking

    @Test("ViewModel tracks selected index")
    func testSelectedIndexTracking() async {
        let mock = MockGUIIPCClient(response: .results([], queryID: "q1"))
        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            #expect(viewModel.selectedIndex == nil)

            viewModel.selectedIndex = 2
            #expect(viewModel.selectedIndex == 2)

            viewModel.selectedIndex = nil
            #expect(viewModel.selectedIndex == nil)
        }
    }

    // MARK: - 5. Open selected calls NSWorkspace

    @Test("openSelected() opens the file at selected index via NSWorkspace")
    func testOpenSelected() async throws {
        let record = makeRecord(id: 1, name: "doc.pdf", path: "/tmp/doc.pdf")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockGUIIPCClient(response: .results([result], queryID: "q1"))

        let workspace = MockWorkspace()
        let viewModel = await SearchViewModel(ipcClient: mock, workspace: workspace)

        await MainActor.run {
            viewModel.searchText = "doc"
        }
        await viewModel.search()

        await MainActor.run {
            viewModel.selectedIndex = 0
        }

        let opened = await viewModel.openSelected()
        #expect(opened == true)

        let openedPath = await workspace.lastOpenedPath
        #expect(openedPath == "/tmp/doc.pdf")
    }

    // MARK: - 6. Clear results on new query

    @Test("Results are cleared when a new search begins")
    func testClearResultsOnNewQuery() async throws {
        // First search returns results
        let r1 = makeRecord(id: 1, name: "alpha.txt", path: "/tmp/alpha.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockGUIIPCClient(response: .results([s1], queryID: "q1"))

        let viewModel = await SearchViewModel(ipcClient: mock)
        await MainActor.run {
            viewModel.searchText = "alpha"
        }
        await viewModel.search()

        var results = await viewModel.results
        #expect(results.count == 1)

        // Second search returns empty
        await mock.setResponse(.results([], queryID: "q2"))
        await MainActor.run {
            viewModel.searchText = "beta"
        }
        await viewModel.search()

        results = await viewModel.results
        #expect(results.isEmpty)
    }

    // MARK: - 7. Loading state management

    @Test("ViewModel isLoading is false before and after search")
    func testLoadingStateManagement() async throws {
        let r1 = makeRecord(id: 1, name: "file.txt", path: "/tmp/file.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockGUIIPCClient(response: .results([s1], queryID: "q1"))

        let viewModel = await SearchViewModel(ipcClient: mock)

        let beforeSearch = await viewModel.isLoading
        #expect(beforeSearch == false)

        await MainActor.run {
            viewModel.searchText = "file"
        }
        await viewModel.search()

        let afterSearch = await viewModel.isLoading
        #expect(afterSearch == false)
    }

    // MARK: - 8. Empty results message

    @Test("ViewModel has no results after search returning empty array")
    func testEmptyResultsMessage() async throws {
        let mock = MockGUIIPCClient(response: .results([], queryID: "q1"))
        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            viewModel.searchText = "nonexistent"
        }
        await viewModel.search()

        let results = await viewModel.results
        #expect(results.isEmpty)

        let hasSearched = await viewModel.hasSearched
        #expect(hasSearched == true)
    }

    // MARK: - 9. Toast auto-dismiss is cancelled on new toast

    @Test("showToast cancels previous dismiss task; last toast wins")
    func testToastCancelsPreviousDismiss() async throws {
        let mock = MockGUIIPCClient(response: .results([], queryID: "q1"))
        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            viewModel.showToast("first")
            // Immediately show a second toast — the first dismiss timer should be cancelled.
            viewModel.showToast("second")
        }

        // Wait long enough for the first timer (if not cancelled) to have fired.
        try await Task.sleep(for: .seconds(0.2))

        let messageAfter = await viewModel.toastMessage
        #expect(messageAfter == "second")
    }

    // MARK: - 10. cancelAllTasks cancels stored tasks

    @Test("cancelAllTasks cancels history search and toast dismiss tasks")
    func testCancelAllTasks() async throws {
        let mock = MockGUIIPCClient(response: .results([], queryID: "q1"))
        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            viewModel.showToast("hello")
            viewModel.cancelAllTasks()
        }

        // Give the cancelled task a chance to (not) run.
        try await Task.sleep(for: .seconds(0.2))

        // Toast message should still be "hello" because the dismiss was cancelled.
        let message = await viewModel.toastMessage
        #expect(message == "hello")
    }

    // MARK: - 11. searchFromHistory sends correct query

    @Test("searchFromHistory sets searchText and triggers search")
    func testSearchFromHistory() async throws {
        let r1 = makeRecord(id: 1, name: "report.pdf", path: "/tmp/report.pdf")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockGUIIPCClient(response: .results([s1], queryID: "q1"))

        let viewModel = await SearchViewModel(ipcClient: mock)

        await MainActor.run {
            viewModel.searchFromHistory("report")
        }

        // Wait for the async search to complete.
        try await Task.sleep(for: .seconds(0.2))

        let results = await viewModel.results
        #expect(results.count == 1)

        let lastReq = await mock.lastRequest
        if case .query(let query, _) = lastReq! {
            #expect(query == "report")
        } else {
            Issue.record("Expected .query request, got \(lastReq!)")
        }
    }
}

// MARK: - Mock IPCClient for GUI tests

actor MockGUIIPCClient: IPCClientProtocol {
    var response: IPCResponse
    var lastRequest: IPCRequest?

    init(response: IPCResponse) {
        self.response = response
    }

    func setResponse(_ response: IPCResponse) {
        self.response = response
    }

    func send(_ request: IPCRequest) async throws -> IPCResponse {
        self.lastRequest = request
        return response
    }
}

// MARK: - Mock Workspace

@MainActor
final class MockWorkspace: WorkspaceProtocol, @unchecked Sendable {
    var lastOpenedPath: String?
    var lastRevealedPath: String?

    nonisolated func open(_ path: String) -> Bool {
        MainActor.assumeIsolated {
            lastOpenedPath = path
            return true
        }
    }

    nonisolated func selectFile(_ path: String) -> Bool {
        MainActor.assumeIsolated {
            lastRevealedPath = path
            return true
        }
    }
}
