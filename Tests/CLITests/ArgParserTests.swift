import Testing
@testable import DeepFinderCLILib

@Suite("ArgParser")
struct ArgParserTests {

    // MARK: - Simple query parsing

    @Test("Simple query parsing")
    func testSimpleQuery() throws {
        let opts = try ArgParser.parse(["hello.txt"])
        #expect(opts.query == "hello.txt")
        #expect(opts.jsonOutput == false)
        #expect(opts.nullOutput == false)
        #expect(opts.sort == nil)
        #expect(opts.limit == nil)
        #expect(opts.offset == nil)
        #expect(opts.reverse == false)
        #expect(opts.verbose == false)
        #expect(opts.showHelp == false)
        #expect(opts.showVersion == false)
        #expect(opts.subcommand == nil)
    }

    // MARK: - --json flag

    @Test("--json flag sets jsonOutput")
    func testJsonFlag() throws {
        let opts = try ArgParser.parse(["--json", "test"])
        #expect(opts.jsonOutput == true)
        #expect(opts.query == "test")
    }

    // MARK: - --0 (null output) flag

    @Test("--0 flag sets nullOutput")
    func testNullOutputFlag() throws {
        let opts = try ArgParser.parse(["--0", "test"])
        #expect(opts.nullOutput == true)
        #expect(opts.query == "test")
    }

    // MARK: - --sort

    @Test("--sort name/size/date")
    func testSortOption() throws {
        let name = try ArgParser.parse(["--sort", "name", "q"])
        #expect(name.sort == .name)

        let size = try ArgParser.parse(["--sort", "size", "q"])
        #expect(size.sort == .size)

        let date = try ArgParser.parse(["--sort", "date", "q"])
        #expect(date.sort == .date)
    }

    // MARK: - --limit N

    @Test("--limit N")
    func testLimit() throws {
        let opts = try ArgParser.parse(["--limit", "10", "q"])
        #expect(opts.limit == 10)
    }

    // MARK: - --offset M

    @Test("--offset M")
    func testOffset() throws {
        let opts = try ArgParser.parse(["--offset", "20", "q"])
        #expect(opts.offset == 20)
    }

    // MARK: - --reverse flag

    @Test("--reverse flag")
    func testReverseFlag() throws {
        let opts = try ArgParser.parse(["--reverse", "q"])
        #expect(opts.reverse == true)
    }

    // MARK: - --verbose flag

    @Test("--verbose flag")
    func testVerboseFlag() throws {
        let opts = try ArgParser.parse(["--verbose", "q"])
        #expect(opts.verbose == true)
    }

    // MARK: - --help flag

    @Test("--help flag")
    func testHelpFlag() throws {
        let opts = try ArgParser.parse(["--help"])
        #expect(opts.showHelp == true)
    }

    // MARK: - --version flag

    @Test("--version flag")
    func testVersionFlag() throws {
        let opts = try ArgParser.parse(["--version"])
        #expect(opts.showVersion == true)
    }

    // MARK: - --bookmark NAME

    @Test("--bookmark NAME")
    func testBookmarkFlag() throws {
        let opts = try ArgParser.parse(["--bookmark", "docs"])
        #expect(opts.bookmark == "docs")
        // No positional query needed in bookmark mode.
        #expect(opts.query == nil)
    }

    @Test("--bookmark requires a value")
    func testBookmarkMissingValue() {
        do {
            _ = try ArgParser.parse(["--bookmark"])
            Issue.record("Expected missingValue error")
        } catch let error as CLIError {
            if case .missingValue(let flag) = error {
                #expect(flag == "--bookmark")
            } else {
                Issue.record("Expected missingValue, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Combined flags

    @Test("Combined flags: --json --limit 10 --sort date 'query'")
    func testCombinedFlags() throws {
        let opts = try ArgParser.parse(["--json", "--limit", "10", "--sort", "date", "my query"])
        #expect(opts.query == "my query")
        #expect(opts.jsonOutput == true)
        #expect(opts.limit == 10)
        #expect(opts.sort == .date)
        #expect(opts.nullOutput == false)
        #expect(opts.reverse == false)
        #expect(opts.verbose == false)
    }

    // MARK: - Unknown flag error

    @Test("Unknown flag throws CLIError.unknownFlag")
    func testUnknownFlag() {
        do {
            _ = try ArgParser.parse(["--bogus", "q"])
            Issue.record("Expected unknownFlag error")
        } catch let error as CLIError {
            if case .unknownFlag(let flag) = error {
                #expect(flag == "--bogus")
            } else {
                Issue.record("Expected unknownFlag, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Missing value for --limit

    @Test("Missing value for --limit throws CLIError.missingValue")
    func testMissingLimitValue() {
        do {
            _ = try ArgParser.parse(["--limit"])
            Issue.record("Expected missingValue error")
        } catch let error as CLIError {
            if case .missingValue(let flag) = error {
                #expect(flag == "--limit")
            } else {
                Issue.record("Expected missingValue, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Empty args returns default options

    @Test("Empty args returns default CLIOptions")
    func testEmptyArgs() throws {
        let opts = try ArgParser.parse([])
        #expect(opts.query == nil)
        #expect(opts.jsonOutput == false)
        #expect(opts.nullOutput == false)
        #expect(opts.sort == nil)
        #expect(opts.limit == nil)
        #expect(opts.offset == nil)
        #expect(opts.reverse == false)
        #expect(opts.verbose == false)
        #expect(opts.showHelp == false)
        #expect(opts.showVersion == false)
        #expect(opts.subcommand == nil)
    }
}
