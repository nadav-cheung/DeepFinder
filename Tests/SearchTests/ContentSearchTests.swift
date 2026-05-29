import Foundation
import Testing
@testable import DeepFinder

@Suite("ContentScanner + ContentSearchProvider")
struct ContentSearchTests {

    // MARK: - Helpers

    /// Create a temporary directory and return its URL. Caller is responsible for removal.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepFinderContentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a string to a file in the given directory, returning the full path.
    @discardableResult
    private func writeFile(in dir: URL, name: String, content: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Write raw bytes to a file in the given directory, returning the full path.
    @discardableResult
    private func writeRawFile(in dir: URL, name: String, data: Data) throws -> String {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    /// Build an InMemoryIndex with records pointing to files in the temp directory.
    private func makeIndexWithFiles(in dir: URL, files: [(name: String, ext: String?)]) async -> InMemoryIndex {
        let index = InMemoryIndex()
        for (name, ext) in files {
            let path = dir.appendingPathComponent(name).path
            await index.insert(
                name: name,
                path: path,
                parentPath: dir.path,
                isDirectory: false,
                size: 100,
                extension: ext
            )
        }
        return index
    }

    // MARK: - ContentScanner Tests

    @Test("Find text in a simple file")
    func testFindTextInSimpleFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeFile(in: dir, name: "hello.txt", content: "line one\nhello world\nline three")

        let matches = ContentScanner.scan(fileAtPath: path, query: "hello")
        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 2)
        #expect(matches[0].lineContent == "hello world")
    }

    @Test("Case insensitive search")
    func testCaseInsensitiveSearch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeFile(in: dir, name: "mixed.txt", content: "Hello World")

        let matches = ContentScanner.scan(fileAtPath: path, query: "hello")
        #expect(matches.count == 1)

        let caseMatches = ContentScanner.scan(
            fileAtPath: path,
            query: "hello",
            options: ScanOptions(caseSensitive: true)
        )
        #expect(caseMatches.count == 0)
    }

    @Test("Multiple matches in one file")
    func testMultipleMatchesInOneFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeFile(in: dir, name: "multi.txt", content: "foo bar\nbaz foo\nfoo qux")

        let matches = ContentScanner.scan(fileAtPath: path, query: "foo")
        #expect(matches.count == 3)
        #expect(matches[0].lineNumber == 1)
        #expect(matches[1].lineNumber == 2)
        #expect(matches[2].lineNumber == 3)
    }

    @Test("Line numbers are correct")
    func testLineNumbersCorrect() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = "line 1\nline 2\nline 3\nline 4\nline 5\n"
        let path = try writeFile(in: dir, name: "lines.txt", content: content)

        let matches = ContentScanner.scan(fileAtPath: path, query: "line 3")
        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 3)
    }

    @Test("Match range is correct")
    func testMatchRangeCorrect() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeFile(in: dir, name: "range.txt", content: "xx hello xx")

        let matches = ContentScanner.scan(fileAtPath: path, query: "hello")
        #expect(matches.count == 1)
        let match = matches[0]

        // "xx hello xx" — "hello" starts at index 3 (after "xx ")
        let range = match.matchRange
        let matchedText = String(match.lineContent[range])
        #expect(matchedText == "hello")
    }

    @Test("Binary files are skipped")
    func testBinaryFilesSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write binary data with a NUL byte, using a text extension
        var data = Data([0x01, 0x02, 0x00, 0x03, 0x04])
        data.append(contentsOf: [UInt8]("hello".utf8))

        // Use .txt extension so it passes extension check but fails binary probe
        let url = dir.appendingPathComponent("binary.txt")
        try data.write(to: url)

        let matches = ContentScanner.scan(fileAtPath: url.path, query: "hello")
        #expect(matches.isEmpty)
    }

    @Test("Non-existent file returns empty")
    func testNonExistentFileReturnsEmpty() {
        let matches = ContentScanner.scan(
            fileAtPath: "/nonexistent/path/file.txt",
            query: "anything"
        )
        #expect(matches.isEmpty)
    }

    @Test("Empty query returns empty")
    func testEmptyQueryReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeFile(in: dir, name: "data.txt", content: "some content")

        let matches = ContentScanner.scan(fileAtPath: path, query: "")
        #expect(matches.isEmpty)
    }

    @Test("UTF-8 BOM file handled correctly")
    func testUTF8BOMHandled() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // UTF-8 BOM (EF BB BF) followed by content
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: [UInt8]("hello world".utf8))
        let url = dir.appendingPathComponent("bom.txt")
        try data.write(to: url)

        let matches = ContentScanner.scan(fileAtPath: url.path, query: "hello")
        #expect(matches.count == 1)
        #expect(matches[0].lineContent == "hello world")
    }

    @Test("Large file streaming with temp file")
    func testLargeFileStreaming() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a file with 10,000 lines, one of which contains the query
        var lines: [String] = []
        for i in 1...10000 {
            if i == 5000 {
                lines.append("line \(i): FINDME target text here")
            } else {
                lines.append("line \(i): ordinary content")
            }
        }
        let path = try writeFile(in: dir, name: "large.log", content: lines.joined(separator: "\n"))

        let matches = ContentScanner.scan(fileAtPath: path, query: "FINDME")
        #expect(matches.count == 1)
        #expect(matches[0].lineNumber == 5000)
        #expect(matches[0].lineContent.contains("FINDME"))
    }
}
