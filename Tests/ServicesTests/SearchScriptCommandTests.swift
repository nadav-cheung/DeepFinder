import Foundation
import Testing
@testable import DeepFinder

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
