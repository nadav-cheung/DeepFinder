import Testing
import Foundation
@testable import DeepFinder

@Suite("REPL")
struct REPLTests {

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

    // MARK: - REPLCommand.parse tests

    @Test(":help parses as help command")
    func testParseHelp() {
        let (cmd, args, isQuery) = REPLCommand.parse(":help")
        #expect(cmd == .help)
        #expect(args.isEmpty)
        #expect(isQuery == false)
    }

    @Test(":quit parses as quit command")
    func testParseQuit() {
        let (cmd, args, _) = REPLCommand.parse(":quit")
        #expect(cmd == .quit)
    }

    @Test(":stats parses as stats command")
    func testParseStats() {
        let (cmd, args, _) = REPLCommand.parse(":stats")
        #expect(cmd == .stats)
        #expect(args.isEmpty)
    }

    @Test(":config parses with key argument")
    func testParseConfig() {
        let (cmd, args, _) = REPLCommand.parse(":config index.path")
        #expect(cmd == .config)
        #expect(args == ["index.path"])
    }

    @Test(":open 3 parses with numeric argument")
    func testParseOpenWithArg() {
        let (cmd, args, _) = REPLCommand.parse(":open 3")
        #expect(cmd == .open)
        #expect(args == ["3"])
    }

    @Test(":reveal 1 parses with numeric argument")
    func testParseParseRevealWithArg() {
        let (cmd, args, _) = REPLCommand.parse(":reveal 1")
        #expect(cmd == .reveal)
        #expect(args == ["1"])
    }

    @Test("Unknown command returns nil command and isQuery false")
    func testParseUnknownCommand() {
        let (cmd, _, isQuery) = REPLCommand.parse(":unknown")
        #expect(cmd == nil)
        #expect(isQuery == false)
    }

    @Test("Commands are case insensitive (:HELP, :Stats)")
    func testParseCaseInsensitive() {
        let (cmd1, _, _) = REPLCommand.parse(":HELP")
        #expect(cmd1 == .help)

        let (cmd2, _, _) = REPLCommand.parse(":Stats")
        #expect(cmd2 == .stats)
    }

    @Test("Alias :q parses as quit")
    func testParseAliasQuit() {
        let (cmd, _, _) = REPLCommand.parse(":q")
        #expect(cmd == .quit)
    }

    @Test("Alias :h parses as help")
    func testParseAliasHelp() {
        let (cmd, _, _) = REPLCommand.parse(":h")
        #expect(cmd == .help)
    }

    @Test("Plain text input is a search query")
    func testParseQueryInput() {
        let (cmd, _, isQuery) = REPLCommand.parse("hello.txt")
        #expect(cmd == nil)
        #expect(isQuery == true)
    }

    @Test("Empty input is not a query")
    func testParseEmptyInput() {
        let (cmd, _, isQuery) = REPLCommand.parse("")
        #expect(cmd == nil)
        #expect(isQuery == false)
    }

    // MARK: - REPLCommand.description test

    @Test(":help lists all commands via description")
    func testHelpListsAllCommands() {
        // Every command case should have a non-empty description
        for command in REPLCommand.allCases {
            #expect(!command.description.isEmpty, ":\(command.rawValue) has empty description")
        }
        // Verify all expected cases exist
        let rawValues = Set(REPLCommand.allCases.map(\.rawValue))
        #expect(rawValues.contains("help"))
        #expect(rawValues.contains("quit"))
        #expect(rawValues.contains("stats"))
        #expect(rawValues.contains("config"))
        #expect(rawValues.contains("open"))
        #expect(rawValues.contains("reveal"))
        #expect(rawValues.contains("daemon"))
    }

    // MARK: - REPL integration tests (with MockInputSource + MockIPCClient)

    @Test("Welcome banner printed on REPL start")
    func testWelcomeBanner() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains(Product.name))
    }

    @Test("Ctrl+D (nil from input) exits REPL")
    func testCtrlDExits() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [])  // Returns nil immediately
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        // Should exit cleanly — welcome banner printed then EOF detected
        let allOutput = output.collected
        #expect(allOutput.contains(Product.name))
    }

    @Test("Query input dispatches to search")
    func testQueryDispatchesToSearch() async {
        let record = makeRecord(id: 1, name: "hello.txt", path: "/tmp/hello.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mockClient = MockIPCClient(response: .results([result], queryID: "q1"))

        let inputSource = MockInputSource(lines: ["hello.txt", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("hello.txt"))

        // Verify the mock received a query request
        let lastReq = await mockClient.lastRequest
        #expect(lastReq != nil)
        if case .query(let q, _) = lastReq! {
            #expect(q == "hello.txt")
        } else {
            Issue.record("Expected query request, got: \(String(describing: lastReq))")
        }
    }

    @Test("Last results stored for :open/:reveal")
    func testLastResultsStored() async {
        let r1 = makeRecord(id: 1, name: "a.txt", path: "/tmp/a.txt")
        let r2 = makeRecord(id: 2, name: "b.txt", path: "/tmp/b.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let s2 = SearchResult(record: r2, providerID: "test", score: 0.8, matchType: .substring)
        let mockClient = MockIPCClient(response: .results([s1, s2], queryID: "q1"))

        let inputSource = MockInputSource(lines: ["test query", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let results = await repl.lastResults
        #expect(results.count == 2)
        #expect(results[0].record.id == 1)
        #expect(results[1].record.id == 2)
    }

    @Test(":open N validates N is valid index")
    func testOpenValidatesIndex() async {
        let record = makeRecord(id: 1, name: "hello.txt", path: "/tmp/hello.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mockClient = MockIPCClient(response: .results([result], queryID: "q1"))

        // First search gets 1 result, then try :open 5 (out of range)
        let inputSource = MockInputSource(lines: ["hello.txt", ":open 5", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Invalid index") || allOutput.contains("invalid") || allOutput.contains("No result"))
    }

    @Test(":reveal N validates N is valid index")
    func testRevealValidatesIndex() async {
        let record = makeRecord(id: 1, name: "hello.txt", path: "/tmp/hello.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mockClient = MockIPCClient(response: .results([result], queryID: "q1"))

        // First search gets 1 result, then try :reveal 99 (out of range)
        let inputSource = MockInputSource(lines: ["hello.txt", ":reveal 99", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Invalid index") || allOutput.contains("invalid") || allOutput.contains("No result"))
    }

    @Test(":help lists all commands in output")
    func testHelpCommandOutput() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [":help", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains(":help"))
        #expect(allOutput.contains(":quit"))
        #expect(allOutput.contains(":stats"))
        #expect(allOutput.contains(":open"))
        #expect(allOutput.contains(":reveal"))
        #expect(allOutput.contains(":config"))
        #expect(allOutput.contains(":daemon"))
    }
}

// MARK: - MockInputSource

/// Returns a predefined sequence of lines, then nil (EOF).
/// Uses nonisolated(unsafe) mutable state because the REPL actor
/// calls readline synchronously from its own isolation domain.
final class MockInputSource: REPLInputSource, @unchecked Sendable {
    nonisolated(unsafe) private var lines: [String]
    nonisolated(unsafe) private var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    func readline(prompt: String) -> String? {
        guard index < lines.count else { return nil }
        let line = lines[index]
        index += 1
        return line
    }
}

// MARK: - REPLTestOutput

/// Captures all REPL output for testing.
/// Uses nonisolated(unsafe) because tests read `collected` after
/// the REPL actor has finished writing.
final class REPLTestOutput: REPLErrorOutput, @unchecked Sendable {
    nonisolated(unsafe) private var buffer: [String] = []

    func write(_ text: String) {
        buffer.append(text)
    }

    func writeError(_ text: String) {
        buffer.append(text)
    }

    /// All output concatenated.
    var collected: String {
        buffer.joined()
    }
}
