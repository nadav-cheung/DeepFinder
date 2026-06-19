import Testing
import Foundation
import DeepFinderIndex
import DeepFinderDaemon
import DeepFinderSearch
@testable import DeepFinderCLILib

@Suite("CLIMain")
struct CLIMainTests {

    // MARK: - Helpers

    /// Make a FileRecord for testing.
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

    // MARK: - 1. Help flag returns success and prints usage

    @Test("--help returns success and prints usage")
    func testHelpFlag() async {
        let (output, exitCode) = await CLIMain.run(args: ["--help"])
        #expect(exitCode == .success)
        #expect(output.stdout.contains("USAGE"))
        #expect(output.stdout.contains("deepfinder"))
    }

    // MARK: - 2. Version flag returns success and prints version

    @Test("--version returns success and prints version")
    func testVersionFlag() async {
        let (output, exitCode) = await CLIMain.run(args: ["--version"])
        #expect(exitCode == .success)
        #expect(output.stdout.contains(Product.name))
    }

    // MARK: - 3. No query returns success (REPL placeholder)

    @Test("No query returns success and prints REPL placeholder")
    func testNoQuery() async {
        let (output, exitCode) = await CLIMain.run(args: [])
        #expect(exitCode == .success)
        // Placeholder message for v0.6 REPL
        #expect(output.stdout.contains("REPL"))
    }

    // MARK: - 4. Successful query returns results

    @Test("Successful query returns results and exit code 0")
    func testSuccessfulQuery() async {
        let record = makeRecord(id: 1, name: "hello.txt", path: "/tmp/hello.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockIPCClient(response: .results([result], queryID: "q1"))

        let (output, exitCode) = await CLIMain.run(args: ["hello.txt"], clientProvider: mock)
        #expect(exitCode == .success)
        #expect(output.stdout.contains("hello.txt"))
    }

    // MARK: - 5. No results returns exitCode 1

    @Test("No results returns exitCode noResults")
    func testNoResults() async {
        let mock = MockIPCClient(response: .results([], queryID: "q1"))

        let (_, exitCode) = await CLIMain.run(args: ["nonexistent"], clientProvider: mock)
        #expect(exitCode == .noResults)
    }

    // MARK: - 6. Daemon error returns exitCode 2

    @Test("Daemon connection error returns exitCode daemonError")
    func testDaemonError() async {
        let mock = MockIPCClient(error: IPCClientError.connectionFailed("test failure"))

        let (_, exitCode) = await CLIMain.run(args: ["test"], clientProvider: mock)
        #expect(exitCode == .daemonError)
    }

    // MARK: - 7. Query with --json outputs JSON

    @Test("--json outputs valid JSON array")
    func testJsonOutput() async {
        let record = makeRecord(id: 1, name: "report.pdf", path: "/tmp/report.pdf")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockIPCClient(response: .results([result], queryID: "q1"))

        let (output, exitCode) = await CLIMain.run(args: ["--json", "report"], clientProvider: mock)
        #expect(exitCode == .success)
        // Should be valid JSON
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonData = trimmed.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: jsonData)
        #expect(parsed != nil)
        #expect(output.stdout.contains("report.pdf"))
    }

    // MARK: - 8. Query with --0 outputs NUL-separated paths

    @Test("--0 outputs NUL-separated paths")
    func testNullOutput() async {
        let r1 = makeRecord(id: 1, name: "a.txt", path: "/tmp/a.txt")
        let r2 = makeRecord(id: 2, name: "b.txt", path: "/tmp/b.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let s2 = SearchResult(record: r2, providerID: "test", score: 0.8, matchType: .substring)
        let mock = MockIPCClient(response: .results([s1, s2], queryID: "q1"))

        let (output, exitCode) = await CLIMain.run(args: ["--0", "txt"], clientProvider: mock)
        #expect(exitCode == .success)
        // NUL-separated: path1\0path2\0
        let paths = output.stdout.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        #expect(paths.count == 2)
        #expect(paths.contains("/tmp/a.txt"))
        #expect(paths.contains("/tmp/b.txt"))
    }

    // MARK: - 9. Query with --limit limits results

    @Test("--limit is passed through to the IPC request")
    func testLimitOption() async {
        let mock = MockIPCClient(response: .results([], queryID: "q1"))

        let (_, exitCode) = await CLIMain.run(args: ["--limit", "5", "test"], clientProvider: mock)
        #expect(exitCode == .noResults)
        // Verify the mock received the correct limit
        let allRequests = await mock.requests
        let queryReq = allRequests.first { if case .query = $0 { true } else { false } }
        #expect(queryReq != nil)
        if case .query(_, let limit) = queryReq! {
            #expect(limit == 5)
        } else {
            Issue.record("Expected query request")
        }
    }

    // MARK: - 10. --sort option is recognized

    @Test("--sort option is recognized and parsed")
    func testSortOption() async {
        let record = makeRecord(id: 1, name: "file.txt", path: "/tmp/file.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockIPCClient(response: .results([result], queryID: "q1"))

        let (output, exitCode) = await CLIMain.run(args: ["--sort", "name", "file"], clientProvider: mock)
        #expect(exitCode == .success)
        #expect(output.stdout.contains("file.txt"))
    }

    // MARK: - 11. --bookmark NAME resolves the saved query and runs it

    @Test("--bookmark NAME resolves the saved query and runs it")
    func testBookmarkResolvesAndRuns() async {
        let record = makeRecord(id: 1, name: "report.pdf", path: "/docs/report.pdf")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mock = MockIPCClient { request in
            switch request {
            case .bookmarkList:
                return .bookmarks([SearchBookmark(name: "docs", query: "report")])
            case .query(let query, _):
                return query == "report" ? .results([result], queryID: "q1") : .results([], queryID: "q2")
            default:
                return nil
            }
        }

        let (output, exitCode) = await CLIMain.run(args: ["--bookmark", "docs"], clientProvider: mock)
        #expect(exitCode == .success)
        #expect(output.stdout.contains("report.pdf"))
    }

    @Test("--bookmark with an unknown name errors")
    func testBookmarkUnknownName() async {
        let mock = MockIPCClient { request in
            switch request {
            case .bookmarkList:
                return .bookmarks([SearchBookmark(name: "docs", query: "report")])
            default:
                return nil
            }
        }

        let (output, exitCode) = await CLIMain.run(args: ["--bookmark", "missing"], clientProvider: mock)
        #expect(exitCode == .queryError)
        #expect(output.stderr.contains("no bookmark"))
    }
}

// MARK: - Mock IPCClientProtocol

/// A mock IPC client for testing CLIMain without a real daemon.
actor MockIPCClient: IPCClientProtocol {
    let response: IPCResponse?
    let error: Error?
    let handler: (@Sendable (IPCRequest) -> IPCResponse?)?
    var lastRequest: IPCRequest?
    var requests: [IPCRequest] = []

    init(response: IPCResponse) {
        self.response = response
        self.error = nil
        self.handler = nil
    }

    init(error: Error) {
        self.response = nil
        self.error = error
        self.handler = nil
    }

    /// Dispatch responses by request type — for tests whose flow sends
    /// multiple distinct IPC requests (e.g. `--bookmark` lists then queries).
    init(handler: @escaping @Sendable (IPCRequest) -> IPCResponse?) {
        self.response = nil
        self.error = nil
        self.handler = handler
    }

    func send(_ request: IPCRequest) async throws -> IPCResponse {
        self.lastRequest = request
        self.requests.append(request)
        if let error {
            throw error
        }
        if let handler, let r = handler(request) {
            return r
        }
        return response!
    }
}
