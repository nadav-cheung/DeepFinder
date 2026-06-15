import Testing
import Foundation
import DeepFinderDaemon
import DeepFinderSearch
import DeepFinderIndex
import DeepFinderAI
@testable import DeepFinderCLILib

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

    @Test(":bm alias parses as bookmark command")
    func testParseBookmarkAlias() {
        let (cmd, args, _) = REPLCommand.parse(":bm save work")
        #expect(cmd == .bookmark)
        #expect(args == ["save", "work"])
    }

    @Test(":sort parses with criterion argument")
    func testParseSort() {
        let (cmd, args, _) = REPLCommand.parse(":sort name")
        #expect(cmd == .sort)
        #expect(args == ["name"])
    }

    @Test(":sort with no args parses for showing current preference")
    func testParseSortNoArgs() {
        let (cmd, args, _) = REPLCommand.parse(":sort")
        #expect(cmd == .sort)
        #expect(args.isEmpty)
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
        #expect(allOutput.contains(":explain"))
        #expect(allOutput.contains(":dataPreview"))
        #expect(allOutput.contains(":undo"))
    }

    // MARK: - :explain tests

    @Test(":explain N parses with numeric argument")
    func testParseExplainWithArg() {
        let (cmd, args, _) = REPLCommand.parse(":explain 2")
        #expect(cmd == .explain)
        #expect(args == ["2"])
    }

    @Test(":explain N shows match type, position, and reason")
    func testExplainShowsMatchDetails() async {
        let record = makeRecord(id: 1, name: "report.pdf", path: "/tmp/report.pdf")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mockClient = MockIPCClient(response: .results([result], queryID: "q1"))

        let inputSource = MockInputSource(lines: ["report.pdf", ":explain 1", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Match type: exact"))
        #expect(allOutput.contains("Position:"))
        #expect(allOutput.contains("Reason:"))
    }

    @Test(":explain without argument shows usage")
    func testExplainNoArg() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [":explain", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Usage: :explain N"))
    }

    @Test(":explain with out-of-range index shows error")
    func testExplainOutOfRange() async {
        let record = makeRecord(id: 1, name: "hello.txt", path: "/tmp/hello.txt")
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let mockClient = MockIPCClient(response: .results([result], queryID: "q1"))

        let inputSource = MockInputSource(lines: ["hello.txt", ":explain 5", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Invalid index"))
    }

    // MARK: - :data_preview tests

    @Test(":data_preview parses as dataPreview command")
    func testParseDataPreview() {
        let (cmd, args, isQuery) = REPLCommand.parse(":data_preview")
        #expect(cmd == .dataPreview)
        #expect(args.isEmpty)
        #expect(isQuery == false)
    }

    @Test(":data_preview outputs JSON sample")
    func testDataPreviewOutput() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [":data_preview", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("example.pdf"))
        #expect(allOutput.contains("name"))
    }

    // MARK: - :undo tests

    @Test(":undo parses as undo command")
    func testParseUndo() {
        let (cmd, args, isQuery) = REPLCommand.parse(":undo")
        #expect(cmd == .undo)
        #expect(args.isEmpty)
        #expect(isQuery == false)
    }

    @Test(":undo with empty history shows nothing to undo")
    func testUndoEmptyHistory() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [":undo", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Nothing to undo."))
    }

    @Test(":undo with history shows undone operation")
    func testUndoWithHistory() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: [":undo", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )

        // Pre-populate operation history
        let operation = NLOperation(
            type: .move,
            sourcePattern: "photos",
            destination: "/Volumes/Backup",
            preview: ["/tmp/photos/a.jpg"]
        )
        await repl.operationHistory.record(operation)

        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Undone: move"))
        #expect(allOutput.contains("photos"))
        #expect(allOutput.contains("/Volumes/Backup"))
    }

    // MARK: - Suggestions (REQ-1.3-07)

    @Test("Empty input shows syntax tips")
    func testEmptyInputShowsSyntaxTips() async {
        let mockClient = MockIPCClient(response: .results([], queryID: "q1"))
        let inputSource = MockInputSource(lines: ["", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Tips:"))
        #expect(allOutput.contains("ext:pdf"))
        #expect(allOutput.contains(":help"))
    }

    @Test("Empty input after queries shows recent searches")
    func testEmptyInputShowsRecentSearches() async {
        let result = SearchResult(
            record: makeRecord(id: 1, name: "test.txt", path: "/test/test.txt"),
            providerID: "file-index", score: 1.0, matchType: .exact
        )
        let mockClient = MockIPCClient(response: .results([result], queryID: "q1"))
        let inputSource = MockInputSource(lines: ["hello.txt", "", ":quit"])
        let output = REPLTestOutput()

        let repl = await REPL(
            client: mockClient,
            inputSource: inputSource,
            output: output,
            historyPath: nil
        )
        await repl.run()

        let allOutput = output.collected
        #expect(allOutput.contains("Recent searches:"))
        #expect(allOutput.contains("hello.txt"))
    }

    // MARK: - CompletionEngine tests

    @Test("CompletionEngine completes :h to :help")
    func testCommandCompletionHelp() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":h")
        #expect(completions.contains(":help"))
    }

    @Test("CompletionEngine completes :st to :stats")
    func testCommandCompletionStats() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":st")
        #expect(completions.contains(":stats"))
    }

    @Test("CompletionEngine completes partial :qu to :quit")
    func testCommandCompletionQuit() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":qu")
        #expect(completions.contains(":quit"))
    }

    @Test("CompletionEngine lists all commands on bare colon")
    func testCommandCompletionAllCommands() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":")
        #expect(completions.contains(":help"))
        #expect(completions.contains(":quit"))
        #expect(completions.contains(":stats"))
        #expect(completions.contains(":config"))
        #expect(completions.contains(":open"))
        #expect(completions.contains(":reveal"))
        #expect(completions.contains(":daemon"))
        #expect(completions.contains(":explain"))
        #expect(completions.contains(":dataPreview"))
        #expect(completions.contains(":undo"))
    }

    @Test("CompletionEngine returns empty for unknown command prefix")
    func testCommandCompletionUnknown() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":xyz")
        #expect(completions.isEmpty)
    }

    @Test("CompletionEngine completes filter keyword ext:")
    func testFilterKeywordCompletionExt() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete("ex")
        #expect(completions.contains("ext:"))
    }

    @Test("CompletionEngine completes filter keyword size:")
    func testFilterKeywordCompletionSize() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete("si")
        #expect(completions.contains("size:"))
    }

    @Test("CompletionEngine completes filter keyword type:")
    func testFilterKeywordCompletionType() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete("ty")
        #expect(completions.contains("type:"))
    }

    @Test("CompletionEngine lists all filter keywords on empty input")
    func testFilterKeywordCompletionAll() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete("")
        // Filter keywords should appear alongside command prefixes
        #expect(completions.contains("ext:"))
        #expect(completions.contains("size:"))
        #expect(completions.contains("type:"))
        #expect(completions.contains("dm:"))
        #expect(completions.contains("path:"))
    }

    @Test("CompletionEngine completes :open with result index")
    func testOpenCompletionWithResults() {
        let r1 = makeRecord(id: 1, name: "a.txt", path: "/tmp/a.txt")
        let r2 = makeRecord(id: 2, name: "b.txt", path: "/tmp/b.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let s2 = SearchResult(record: r2, providerID: "test", score: 0.8, matchType: .substring)
        let engine = CompletionEngine(lastResults: [s1, s2])
        let completions = engine.complete(":open ")
        // Completions are "1  a.txt" and "2  b.txt" (index + filename for readability)
        #expect(completions.count == 2)
        #expect(completions[0].hasPrefix("1"))
        #expect(completions[0].contains("a.txt"))
        #expect(completions[1].hasPrefix("2"))
        #expect(completions[1].contains("b.txt"))
    }

    @Test("CompletionEngine completes :reveal with result index")
    func testRevealCompletionWithResults() {
        let r1 = makeRecord(id: 1, name: "a.txt", path: "/tmp/a.txt")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let engine = CompletionEngine(lastResults: [s1])
        let completions = engine.complete(":reveal ")
        #expect(completions.count == 1)
        #expect(completions[0].hasPrefix("1"))
        #expect(completions[0].contains("a.txt"))
    }

    @Test("CompletionEngine returns empty :open/:reveal without results")
    func testOpenCompletionNoResults() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":open ")
        #expect(completions.isEmpty)
    }

    @Test("CompletionEngine completes filenames from last results")
    func testFilenameCompletionFromResults() {
        let r1 = makeRecord(id: 1, name: "report.pdf", path: "/tmp/report.pdf")
        let r2 = makeRecord(id: 2, name: "readme.md", path: "/tmp/readme.md")
        let s1 = SearchResult(record: r1, providerID: "test", score: 1.0, matchType: .exact)
        let s2 = SearchResult(record: r2, providerID: "test", score: 0.8, matchType: .substring)
        let engine = CompletionEngine(lastResults: [s1, s2])
        let completions = engine.complete("rep")
        #expect(completions.contains("report.pdf"))
    }

    @Test("CompletionEngine is case insensitive for commands")
    func testCommandCompletionCaseInsensitive() {
        let engine = CompletionEngine(lastResults: [])
        let completions = engine.complete(":HE")
        #expect(completions.contains(":help"))
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
final class REPLTestOutput: CLIOutputWriter, @unchecked Sendable {
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
