import Foundation
import Testing
@testable import DeepFinderServices

@Suite("SearchScriptParser")
struct SearchScriptCommandTests {

    // MARK: - extractQuery

    @Test("extractQuery returns query from directParameter string")
    func extractQueryFromDirectParameter() {
        let args: [String: Any] = ["DirectParameter": "report.pdf"]
        #expect(SearchScriptParser.extractQuery(from: args) == "report.pdf")
    }

    @Test("extractQuery returns nil when directParameter is missing")
    func extractQueryMissingDirectParameter() {
        let args: [String: Any] = [:]
        #expect(SearchScriptParser.extractQuery(from: args) == nil)
    }

    @Test("extractQuery returns nil when directParameter is empty string")
    func extractQueryEmptyDirectParameter() {
        let args: [String: Any] = ["DirectParameter": ""]
        #expect(SearchScriptParser.extractQuery(from: args) == nil)
    }

    @Test("extractQuery returns nil when directParameter is not a String")
    func extractQueryNonStringDirectParameter() {
        let args: [String: Any] = ["DirectParameter": 42]
        #expect(SearchScriptParser.extractQuery(from: args) == nil)
    }

    @Test("extractQuery trims whitespace from query")
    func extractQueryTrimsWhitespace() {
        let args: [String: Any] = ["DirectParameter": "  report  "]
        #expect(SearchScriptParser.extractQuery(from: args) == "report")
    }

    // MARK: - SearchScriptResult

    @Test("SearchScriptResult holds array of paths")
    func resultHoldsPaths() {
        let result = SearchScriptResult(paths: ["/Users/test/file.txt", "/Users/test/doc.pdf"])
        #expect(result.paths == ["/Users/test/file.txt", "/Users/test/doc.pdf"])
    }

    @Test("SearchScriptResult empty paths")
    func resultEmptyPaths() {
        let result = SearchScriptResult(paths: [])
        #expect(result.paths.isEmpty)
    }

    @Test("SearchScriptResult is Sendable and Equatable")
    func resultSendableEquatable() {
        let a = SearchScriptResult(paths: ["/a"])
        let b = SearchScriptResult(paths: ["/a"])
        let c = SearchScriptResult(paths: ["/b"])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - DeepFinderSearchCommand placeholder result

    @Test("DeepFinderSearchCommand.performSearch returns empty result for valid query")
    func performSearchReturnsEmptyForValidQuery() {
        let result = DeepFinderSearchCommand.performSearch(query: "test")
        #expect(result.paths.isEmpty)
    }

    @Test("DeepFinderSearchCommand.performSearch returns empty result for nil query")
    func performSearchReturnsEmptyForNilQuery() {
        let result = DeepFinderSearchCommand.performSearch(query: nil)
        #expect(result.paths.isEmpty)
    }
}

@Suite("FileInfoScriptParser")
struct FileInfoScriptCommandTests {

    // MARK: - extractPath

    @Test("extractPath returns path from directParameter string")
    func extractPathFromDirectParameter() {
        let args: [String: Any] = ["DirectParameter": "/Users/test/report.pdf"]
        #expect(FileInfoScriptParser.extractPath(from: args) == "/Users/test/report.pdf")
    }

    @Test("extractPath returns nil when directParameter is missing")
    func extractPathMissingDirectParameter() {
        let args: [String: Any] = [:]
        #expect(FileInfoScriptParser.extractPath(from: args) == nil)
    }

    @Test("extractPath returns nil when directParameter is empty string")
    func extractPathEmptyDirectParameter() {
        let args: [String: Any] = ["DirectParameter": ""]
        #expect(FileInfoScriptParser.extractPath(from: args) == nil)
    }

    @Test("extractPath returns nil when directParameter is not a String")
    func extractPathNonStringDirectParameter() {
        let args: [String: Any] = ["DirectParameter": 42]
        #expect(FileInfoScriptParser.extractPath(from: args) == nil)
    }

    @Test("extractPath trims whitespace from path")
    func extractPathTrimsWhitespace() {
        let args: [String: Any] = ["DirectParameter": "  /Users/test/report.pdf  "]
        #expect(FileInfoScriptParser.extractPath(from: args) == "/Users/test/report.pdf")
    }

    // MARK: - FileInfoScriptResult

    @Test("FileInfoScriptResult holds info dictionary")
    func resultHoldsInfo() {
        let info: [String: String] = ["name": "report.pdf", "size": "4096"]
        let result = FileInfoScriptResult(info: info)
        #expect(result.info["name"] == "report.pdf")
        #expect(result.info["size"] == "4096")
    }

    @Test("FileInfoScriptResult empty info")
    func resultEmptyInfo() {
        let result = FileInfoScriptResult(info: [:])
        #expect(result.info.isEmpty)
    }

    @Test("FileInfoScriptResult is Sendable and Equatable")
    func resultSendableEquatable() {
        let a = FileInfoScriptResult(info: ["name": "a"])
        let b = FileInfoScriptResult(info: ["name": "a"])
        let c = FileInfoScriptResult(info: ["name": "b"])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - DeepFinderGetFileInfoCommand placeholder result

    @Test("DeepFinderGetFileInfoCommand.performFileInfo returns empty result for valid path")
    func performFileInfoReturnsEmptyForValidPath() {
        let result = DeepFinderGetFileInfoCommand.performFileInfo(path: "/Users/test/nonexistent.pdf")
        #expect(result.info.isEmpty)
    }

    @Test("DeepFinderGetFileInfoCommand.performFileInfo returns empty result for nil path")
    func performFileInfoReturnsEmptyForNilPath() {
        let result = DeepFinderGetFileInfoCommand.performFileInfo(path: nil)
        #expect(result.info.isEmpty)
    }

    @Test("DeepFinderGetFileInfoCommand.performFileInfo returns empty result for empty path")
    func performFileInfoReturnsEmptyForEmptyPath() {
        let result = DeepFinderGetFileInfoCommand.performFileInfo(path: "")
        #expect(result.info.isEmpty)
    }
}
