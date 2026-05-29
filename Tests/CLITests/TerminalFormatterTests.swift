import Testing
import Foundation
@testable import DeepFinder

@Suite("TerminalFormatter")
struct TerminalFormatterTests {

    // MARK: - Helpers

    private func makeRecord(
        name: String = "test.txt",
        path: String = "/Users/dev/test.txt",
        size: Int64 = 1024,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FileRecord {
        FileRecord(
            id: 1,
            name: name,
            originalName: name,
            path: path,
            parentPath: (path as NSString).deletingLastPathComponent,
            isDirectory: false,
            size: size,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            extension: (name as NSString).pathExtension
        )
    }

    private func makeResult(
        name: String = "test.txt",
        path: String = "/Users/dev/test.txt",
        size: Int64 = 1024,
        matchType: MatchType = .substring,
        score: Double = 1.0
    ) -> SearchResult {
        let record = makeRecord(name: name, path: path, size: size)
        return SearchResult(record: record, providerID: "test", score: score, matchType: matchType)
    }

    // MARK: - 1. JSON output format (valid JSON array)

    @Test("JSON output produces valid JSON array")
    func testJSONOutput() throws {
        let results = [makeResult()]
        var opts = CLIOptions()
        opts.jsonOutput = true
        opts.query = "test"

        let output = TerminalFormatter.format(results, options: opts)

        let data = output.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [Any])
    }

    // MARK: - 2. NUL output format (paths separated by \0)

    @Test("NUL output: paths separated by null bytes")
    func testNULOutput() {
        let r1 = makeResult(name: "a.txt", path: "/tmp/a.txt")
        let r2 = makeResult(name: "b.txt", path: "/tmp/b.txt")
        var opts = CLIOptions()
        opts.nullOutput = true

        let output = TerminalFormatter.format([r1, r2], options: opts)

        // NUL-separated, trailing NUL is acceptable
        #expect(output.contains("/tmp/a.txt"))
        #expect(output.contains("/tmp/b.txt"))
        let parts = output.split(separator: "\0", omittingEmptySubsequences: false)
        #expect(parts.filter { !$0.isEmpty }.count == 2)
    }

    // MARK: - 3. ANSI output contains filename

    @Test("ANSI output contains the filename")
    func testANSIOutputContainsFilename() {
        let results = [makeResult(name: "report.pdf")]
        var opts = CLIOptions()
        opts.query = "report"

        let output = TerminalFormatter.format(results, options: opts)

        #expect(output.contains("report.pdf"))
    }

    // MARK: - 4. Highlight matches single occurrence

    @Test("highlightMatches wraps single occurrence with ANSI codes")
    func testHighlightSingleOccurrence() {
        let highlighted = TerminalFormatter.highlightMatches(
            in: "hello world",
            query: "world"
        )
        // Should contain bold-on and selective reset (bold-off + default-fg)
        #expect(highlighted.contains("\u{1B}[1m"))
        #expect(highlighted.contains("\u{1B}[22m"))
        #expect(highlighted.contains("\u{1B}[39m"))
        #expect(highlighted.contains("world"))
    }

    // MARK: - 5. Highlight matches multiple occurrences

    @Test("highlightMatches wraps all occurrences")
    func testHighlightMultipleOccurrences() {
        let highlighted = TerminalFormatter.highlightMatches(
            in: "abc abc abc",
            query: "abc"
        )
        // Count bold markers — should be 3 opening + 3 closing
        let boldCount = highlighted.components(separatedBy: "\u{1B}[1m").count - 1
        #expect(boldCount == 3)
    }

    // MARK: - 6. No ANSI when not a terminal (plain format path)

    @Test("Plain format path output contains no ANSI escape codes")
    func testNoANSIWhenNotTerminal() {
        let results = [makeResult(name: "photo.jpg")]
        var opts = CLIOptions()
        opts.query = "photo"

        let output = TerminalFormatter.format(results, options: opts, isTerminal: false)

        // Should not contain escape sequences in plain-text path output
        #expect(!output.contains("\u{1B}["))
        #expect(output.contains("photo.jpg"))
    }

    // MARK: - 7. Path shortening ~/

    @Test("shortenPath replaces home directory with ~/")
    func testShortenPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Documents/file.txt"
        let shortened = TerminalFormatter.shortenPath(path)
        #expect(shortened == "~/Documents/file.txt")
    }

    @Test("shortenPath leaves non-home paths unchanged")
    func testShortenPathNonHome() {
        let shortened = TerminalFormatter.shortenPath("/usr/local/bin/swift")
        #expect(shortened == "/usr/local/bin/swift")
    }

    // MARK: - 8. File size formatting

    @Test("formatFileSize: 1024 -> '1 KB'")
    func testFileSizeKB() {
        #expect(TerminalFormatter.formatFileSize(1024) == "1 KB")
    }

    @Test("formatFileSize: 1048576 -> '1 MB'")
    func testFileSizeMB() {
        #expect(TerminalFormatter.formatFileSize(1_048_576) == "1 MB")
    }

    @Test("formatFileSize: 1073741824 -> '1 GB'")
    func testFileSizeGB() {
        #expect(TerminalFormatter.formatFileSize(1_073_741_824) == "1 GB")
    }

    @Test("formatFileSize: 500 -> '500 B'")
    func testFileSizeBytes() {
        #expect(TerminalFormatter.formatFileSize(500) == "500 B")
    }

    // MARK: - 9. Empty results returns empty string

    @Test("Empty results returns empty string")
    func testEmptyResults() {
        var opts = CLIOptions()
        opts.query = "nothing"
        let output = TerminalFormatter.format([], options: opts)
        #expect(output == "")
    }

    // MARK: - 10. Match type indicator in verbose mode

    @Test("Verbose mode shows match type indicator")
    func testMatchTypeIndicator() {
        let results = [makeResult(matchType: .exact)]
        var opts = CLIOptions()
        opts.verbose = true
        opts.query = "test"

        let output = TerminalFormatter.format(results, options: opts)

        #expect(output.contains("[exact]"))
    }

    // MARK: - 11. Sort order preserved in output

    @Test("Output preserves input sort order")
    func testSortOrderPreserved() {
        let r1 = makeResult(name: "alpha.txt", path: "/a/alpha.txt")
        let r2 = makeResult(name: "beta.txt", path: "/b/beta.txt")
        var opts = CLIOptions()
        opts.query = "txt"

        let output = TerminalFormatter.format([r1, r2], options: opts)

        let alphaRange = output.range(of: "alpha.txt")!
        let betaRange = output.range(of: "beta.txt")!
        #expect(alphaRange.lowerBound < betaRange.lowerBound)
    }

    // MARK: - 12. Score not shown in non-verbose mode

    @Test("Score is not shown in non-verbose mode")
    func testScoreHiddenInNonVerbose() {
        let results = [makeResult(score: 0.95)]
        var opts = CLIOptions()
        opts.verbose = false
        opts.query = "test"

        let output = TerminalFormatter.format(results, options: opts)

        // Score "0.95" should not appear in the output
        #expect(!output.contains("0.95"))
    }

    // MARK: - 13. Selective reset does not use blanket [0m

    @Test("highlightMatches uses selective reset [22m [39m, not blanket [0m")
    func testSelectiveReset() {
        let highlighted = TerminalFormatter.highlightMatches(
            in: "report",
            query: "port"
        )
        // Should NOT contain the blanket reset [0m
        #expect(!highlighted.contains("\u{1B}[0m"))
        // Should contain selective resets
        #expect(highlighted.contains("\u{1B}[22m"))
        #expect(highlighted.contains("\u{1B}[39m"))
    }

    // MARK: - 14. Empty text returns empty string

    @Test("highlightMatches on empty text returns empty string")
    func testHighlightEmptyText() {
        let highlighted = TerminalFormatter.highlightMatches(
            in: "",
            query: "test"
        )
        #expect(highlighted == "")
    }

    // MARK: - 15. Highlight at string boundaries

    @Test("highlightMatches works at start and end of string")
    func testHighlightAtBoundaries() {
        // Match at start
        let atStart = TerminalFormatter.highlightMatches(in: "abc def", query: "abc")
        #expect(atStart.hasPrefix("\u{1B}[1m"))

        // Match at end
        let atEnd = TerminalFormatter.highlightMatches(in: "abc def", query: "def")
        #expect(atEnd.hasSuffix("\u{1B}[39m"))
    }
}
