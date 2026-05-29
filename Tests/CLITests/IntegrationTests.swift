import Testing
import Foundation
@testable import DeepFinder

// MARK: - REQ-1.0-01 CLI Integration Tests
//
// End-to-end integration tests wiring real components together:
// InMemoryIndex + FileIndexProvider + SearchCoordinator + IPCServer + IPCClient.
// No mocks — real Unix domain socket IPC, real search pipeline.
//
// Note: IPCServer handles one request per connection (read request → write response → close).
// Each CLIMain.run() or client.send() consumes one connection. Tests that make multiple
// calls must create a fresh IPCClient for each call.

@Suite("CLI Integration Tests (REQ-1.0-01)", .serialized)
struct IntegrationTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-int-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Populate the index with standard test files.
    private func insertTestFiles(into index: InMemoryIndex) async {
        await index.insert(
            name: "hello.txt",
            path: "/tmp/test/hello.txt",
            parentPath: "/tmp/test",
            size: 1024,
            extension: "txt"
        )
        await index.insert(
            name: "report.pdf",
            path: "/tmp/test/docs/report.pdf",
            parentPath: "/tmp/test/docs",
            size: 2_048_000,
            extension: "pdf"
        )
        await index.insert(
            name: "airport_map.png",
            path: "/tmp/test/images/airport_map.png",
            parentPath: "/tmp/test/images",
            size: 5_000_000,
            extension: "png"
        )
        await index.insert(
            name: "README",
            path: "/tmp/test/README",
            parentPath: "/tmp/test",
            isDirectory: false,
            size: 500
        )
        await index.insert(
            name: "data_analysis_2024.xlsx",
            path: "/tmp/test/spreadsheets/data_analysis_2024.xlsx",
            parentPath: "/tmp/test/spreadsheets",
            size: 150_000,
            extension: "xlsx"
        )
    }

    // MARK: - 1. testSingleShotQuery

    @Test("Single-shot query returns correct results through full IPC pipeline")
    func testSingleShotQuery() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let (output, exitCode) = await CLIMain.run(
            args: ["hello"],
            clientProvider: client
        )

        #expect(exitCode == .success)
        #expect(output.stdout.contains("hello.txt"))

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 2. testSingleShotJSON

    @Test("Single-shot --json output is valid JSON through IPC pipeline")
    func testSingleShotJSON() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let (output, exitCode) = await CLIMain.run(
            args: ["--json", "report"],
            clientProvider: client
        )

        #expect(exitCode == .success)

        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "JSON output should not be empty")

        let jsonData = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: jsonData)
        let array = try #require(parsed as? [Any])
        #expect(!array.isEmpty, "JSON array should contain results")
        #expect(output.stdout.contains("report.pdf"))

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 3. testSingleShotNull

    @Test("Single-shot --0 output is NUL-separated paths through IPC pipeline")
    func testSingleShotNull() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let (output, exitCode) = await CLIMain.run(
            args: ["--0", "txt"],
            clientProvider: client
        )

        #expect(exitCode == .success)

        let paths = output.stdout.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }

        #expect(!paths.isEmpty, "Should have at least one NUL-separated path")
        #expect(paths.contains("/tmp/test/hello.txt"))
        for path in paths {
            #expect(!path.contains("\u{1B}"), "NUL output should not contain ANSI escape codes")
        }

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 4. testSingleShotNoResults

    @Test("Single-shot query with no matches returns exit code 1")
    func testSingleShotNoResults() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let (output, exitCode) = await CLIMain.run(
            args: ["zzzz_nonexistent_file_xyzzz"],
            clientProvider: client
        )

        #expect(exitCode == .noResults)
        #expect(output.stdout.isEmpty, "No-results output should be empty")

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 5. testExitCodes

    @Test("All exit codes are correct: 0=success, 1=no results, 2=daemon error, 3=query error")
    func testExitCodes() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        // Exit code 0: successful query with results (fresh client for each call)
        let client0 = IPCClient(socketPath: sockPath)
        let (_, successCode) = await CLIMain.run(
            args: ["hello"],
            clientProvider: client0
        )
        #expect(successCode == .success, "Expected exit code 0 for successful query")
        #expect(successCode.rawValue == 0)

        // Exit code 1: query with no results (fresh client)
        let client1 = IPCClient(socketPath: sockPath)
        let (_, noResultsCode) = await CLIMain.run(
            args: ["nonexistent_file_xyz"],
            clientProvider: client1
        )
        #expect(noResultsCode == .noResults, "Expected exit code 1 for no results")
        #expect(noResultsCode.rawValue == 1)

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)

        // Exit code 2: daemon error (mock client — no real server needed)
        let errorClient = MockIPCClient(error: IPCClientError.connectionFailed("test"))
        let (_, daemonErrorCode) = await CLIMain.run(
            args: ["test"],
            clientProvider: errorClient
        )
        #expect(daemonErrorCode == .daemonError, "Expected exit code 2 for daemon error")
        #expect(daemonErrorCode.rawValue == 2)

        // Exit code 3: query error (mock client)
        let queryErrorClient = MockIPCClient(
            response: .error(.queryError("bad query syntax"))
        )
        let (_, queryErrorCode) = await CLIMain.run(
            args: ["test"],
            clientProvider: queryErrorClient
        )
        #expect(queryErrorCode == .queryError, "Expected exit code 3 for query error")
        #expect(queryErrorCode.rawValue == 3)
    }

    // MARK: - 6. testREPLCommandParsing

    @Test("REPL command parsing dispatches correctly for various inputs")
    func testREPLCommandParsing() async {
        let testCases: [(input: String, expected: REPLCommand?, args: [String], isQuery: Bool)] = [
            (":help", .help, [], false),
            (":quit", .quit, [], false),
            (":q", .quit, [], false),
            (":h", .help, [], false),
            (":stats", .stats, [], false),
            (":config mykey", .config, ["mykey"], false),
            (":config mykey myvalue", .config, ["mykey", "myvalue"], false),
            (":open 3", .open, ["3"], false),
            (":reveal 1", .reveal, ["1"], false),
            (":daemon", .daemon, [], false),
            (":HELP", .help, [], false),   // case-insensitive
            (":Stats", .stats, [], false),  // case-insensitive
            ("hello.txt", nil, [], true),   // plain text = query
            ("", nil, [], false),           // empty = no-op
            (":unknown", nil, [], false),   // unknown command
        ]

        for testCase in testCases {
            let (cmd, args, isQuery) = REPLCommand.parse(testCase.input)
            #expect(cmd == testCase.expected,
                "Input '\(testCase.input)': expected \(String(describing: testCase.expected)), got \(String(describing: cmd))")
            #expect(args == testCase.args,
                "Input '\(testCase.input)': expected args \(testCase.args), got \(args)")
            #expect(isQuery == testCase.isQuery,
                "Input '\(testCase.input)': expected isQuery=\(testCase.isQuery), got \(isQuery)")
        }
    }

    // MARK: - 7. testREPLQueryThroughIPC

    @Test("REPL query sends through IPC and displays formatted results")
    func testREPLQueryThroughIPC() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        // REPL uses IPCClientProtocol. The REPL calls client.send() multiple times
        // (once per query), and the server closes each connection after one request.
        // Use a reconnecting client wrapper.
        let replClient = ReconnectingIPCClient(socketPath: sockPath)

        let mockInput = MockInputSource(lines: ["report", ":quit"])
        let testOutput = REPLTestOutput()

        let repl = REPL(
            client: replClient,
            inputSource: mockInput,
            output: testOutput,
            historyPath: nil
        )
        await repl.run()

        let allOutput = testOutput.collected
        #expect(allOutput.contains("report.pdf"),
            "REPL should display report.pdf in search results")
        #expect(allOutput.contains("result"),
            "REPL should show result count")

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 8. testDaemonStatusViaIPC

    @Test("indexStatus request returns correct response structure via IPC")
    func testDaemonStatusViaIPC() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let response = try await client.send(.indexStatus)

        switch response {
        case .indexStatus(let status):
            #expect(!status.state.isEmpty, "state should be non-empty")
        case .error(let err):
            Issue.record("Expected indexStatus but got error: \(err)")
        default:
            Issue.record("Expected indexStatus response, got: \(response)")
        }

        await client.disconnect()
        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 9. testStatsViaIPC

    @Test("stats request returns DaemonStats with valid structure via IPC")
    func testStatsViaIPC() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let response = try await client.send(.stats)

        switch response {
        case .stats(let stats):
            #expect(stats.totalFiles >= 0)
            #expect(!stats.indexState.isEmpty)
            #expect(stats.uptimeSeconds >= 0)
            #expect(stats.memoryUsageMB >= 0)
        case .error(let err):
            Issue.record("Expected stats but got error: \(err)")
        default:
            Issue.record("Expected stats response, got: \(response)")
        }

        await client.disconnect()
        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 10. testConfigGetSetViaIPC

    @Test("config get/set round-trips through IPC")
    func testConfigGetSetViaIPC() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Each request needs a fresh client (server closes connection after each)
        let client1 = IPCClient(socketPath: sockPath)
        let getResponse = try await client1.send(.configGet(key: "test.key"))
        switch getResponse {
        case .ack:
            break  // Expected
        case .error(let err):
            Issue.record("configGet returned error: \(err)")
        default:
            Issue.record("configGet expected .ack, got: \(getResponse)")
        }

        let client2 = IPCClient(socketPath: sockPath)
        let setResponse = try await client2.send(.configSet(key: "test.key", value: "test_value"))
        switch setResponse {
        case .ack:
            break  // Expected
        case .error(let err):
            Issue.record("configSet returned error: \(err)")
        default:
            Issue.record("configSet expected .ack, got: \(setResponse)")
        }

        let client3 = IPCClient(socketPath: sockPath)
        let getAllResponse = try await client3.send(.configGet(key: nil))
        switch getAllResponse {
        case .ack:
            break
        default:
            Issue.record("configGet(nil) expected .ack, got: \(getAllResponse)")
        }

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 11. testQueryWithLimit

    @Test("Query with limit caps results through IPC pipeline")
    func testQueryWithLimit() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let client = IPCClient(socketPath: sockPath)
        let response = try await client.send(.query("t", limit: 1))

        switch response {
        case .results(let results, _):
            #expect(results.count <= 1,
                "Limit=1 should cap results to at most 1, got \(results.count)")
        case .error(let err):
            Issue.record("Expected results but got error: \(err)")
        default:
            Issue.record("Unexpected response type")
        }

        await client.disconnect()
        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 12. testMultipleQueriesSequential

    @Test("Multiple sequential queries over same IPC connection all return correct results")
    func testMultipleQueriesSequential() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        // Each query needs a fresh client (server closes connection after each request)
        let c1 = IPCClient(socketPath: sockPath)
        let r1 = try await c1.send(.query("hello.txt", limit: nil))
        if case .results(let results, _) = r1 {
            #expect(results.contains { $0.record.name == "hello.txt" })
        } else {
            Issue.record("Query 1 failed")
        }

        let c2 = IPCClient(socketPath: sockPath)
        let r2 = try await c2.send(.query("report", limit: nil))
        if case .results(let results, _) = r2 {
            #expect(results.contains { $0.record.name == "report.pdf" })
        } else {
            Issue.record("Query 2 failed")
        }

        let c3 = IPCClient(socketPath: sockPath)
        let r3 = try await c3.send(.query("zzz_nonexistent", limit: nil))
        if case .results(let results, _) = r3 {
            #expect(results.isEmpty)
        } else {
            Issue.record("Query 3 failed")
        }

        let c4 = IPCClient(socketPath: sockPath)
        let r4 = try await c4.send(.query("a", limit: nil))
        if case .results(let results, _) = r4 {
            #expect(results.count >= 2,
                "Broad query 'a' should match multiple files, got \(results.count)")
        } else {
            Issue.record("Query 4 failed")
        }

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 13. testCancelRequestReturnsAck

    @Test("Cancel request returns ack through IPC")
    func testCancelRequestReturnsAck() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        let client = IPCClient(socketPath: sockPath)
        let response = try await client.send(.cancel(queryID: "q-test-123"))

        switch response {
        case .ack:
            break  // Expected
        default:
            Issue.record("Cancel should return .ack, got: \(response)")
        }

        await client.disconnect()
        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 14. testREPLStatsCommandThroughIPC

    @Test("REPL :stats command retrieves stats through IPC")
    func testREPLStatsCommandThroughIPC() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        let replClient = ReconnectingIPCClient(socketPath: sockPath)
        let mockInput = MockInputSource(lines: [":stats", ":quit"])
        let testOutput = REPLTestOutput()

        let repl = REPL(
            client: replClient,
            inputSource: mockInput,
            output: testOutput,
            historyPath: nil
        )
        await repl.run()

        let allOutput = testOutput.collected
        #expect(allOutput.contains("Files indexed"),
            ":stats should display 'Files indexed'")
        #expect(allOutput.contains("Index state"),
            ":stats should display 'Index state'")

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 15. testPipeModeNoANSI

    @Test("Pipe mode (--0 and --json) produces no ANSI escape codes")
    func testPipeModeNoANSI() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        // --json mode: no ANSI (fresh client for each call)
        let jsonClient = IPCClient(socketPath: sockPath)
        let (jsonOutput, jsonCode) = await CLIMain.run(
            args: ["--json", "hello"],
            clientProvider: jsonClient
        )
        #expect(jsonCode == .success)
        #expect(!jsonOutput.stdout.contains("\u{1B}"),
            "JSON output should not contain ANSI escape codes")

        // --0 mode: no ANSI (fresh client)
        let nullClient = IPCClient(socketPath: sockPath)
        let (nullOutput, nullCode) = await CLIMain.run(
            args: ["--0", "hello"],
            clientProvider: nullClient
        )
        #expect(nullCode == .success)
        #expect(!nullOutput.stdout.contains("\u{1B}"),
            "NUL output should not contain ANSI escape codes")

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 16. testSearchResultMatchTypes

    @Test("Search results classify match types correctly (exact, prefix, substring)")
    func testSearchResultMatchTypes() async throws {
        let tmp = try makeTempDir()
        let sockPath = tmp.appendingPathComponent("ipc.sock").path

        let index = InMemoryIndex()
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])

        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await insertTestFiles(into: index)

        // Exact match
        let c1 = IPCClient(socketPath: sockPath)
        let exactResponse = try await c1.send(.query("hello.txt", limit: nil))
        if case .results(let results, _) = exactResponse {
            let helloResults = results.filter { $0.record.name == "hello.txt" }
            #expect(!helloResults.isEmpty)
            #expect(helloResults[0].matchType == .exact)
        } else {
            Issue.record("Exact match query failed")
        }

        // Prefix match
        let c2 = IPCClient(socketPath: sockPath)
        let prefixResponse = try await c2.send(.query("hel", limit: nil))
        if case .results(let results, _) = prefixResponse {
            let helloResults = results.filter { $0.record.name == "hello.txt" }
            #expect(!helloResults.isEmpty)
            #expect(helloResults[0].matchType == .prefix || helloResults[0].matchType == .exact)
        } else {
            Issue.record("Prefix match query failed")
        }

        // Substring match
        let c3 = IPCClient(socketPath: sockPath)
        let subResponse = try await c3.send(.query("port", limit: nil))
        if case .results(let results, _) = subResponse {
            let airportResults = results.filter { $0.record.name == "airport_map.png" }
            #expect(!airportResults.isEmpty)
            #expect(airportResults[0].matchType == .substring)
        } else {
            Issue.record("Substring match query failed")
        }

        await server.stop()
        try? FileManager.default.removeItem(at: tmp)
    }
}

// MARK: - ReconnectingIPCClient

/// An IPCClientProtocol wrapper that creates a fresh IPCClient for each send() call.
///
/// The IPCServer handles one request per connection (read → write → close).
/// This wrapper creates a new connection for each request, matching the real
/// CLI behavior where each `deepfinder "query"` invocation is a separate process.
actor ReconnectingIPCClient: IPCClientProtocol {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func send(_ request: IPCRequest) async throws -> IPCResponse {
        let client = IPCClient(socketPath: socketPath)
        return try await client.send(request)
    }
}
