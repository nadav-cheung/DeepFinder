import Foundation
import Testing
@testable import DeepFinderAI

@Suite("ResultSummarizer")
struct ResultSummarizerTests {

    // MARK: - Nil provider returns nil

    @Test("Nil provider returns nil")
    func nilProviderReturnsNil() async {
        let summarizer = ResultSummarizer(provider: nil)
        let results = [makeSummary(name: "report.pdf")]
        let result = await summarizer.summarize(query: "report", results: results)
        #expect(result == nil)
    }

    // MARK: - Empty results returns nil

    @Test("Empty results returns nil")
    func emptyResultsReturnsNil() async {
        let provider = MockSummarizerProvider(response: "Some summary")
        let summarizer = ResultSummarizer(provider: provider)
        let result = await summarizer.summarize(query: "report", results: [])
        #expect(result == nil)
    }

    // MARK: - Summarize returns string under 100 chars

    @Test("Summarize returns a non-empty string")
    func summarizeReturnsString() async {
        let provider = MockSummarizerProvider(response: "Found 200 files, mostly PDF reports and Excel spreadsheets.")
        let summarizer = ResultSummarizer(provider: provider)
        let results = (0..<5).map { makeSummary(name: "report_\($0).pdf") }
        let result = await summarizer.summarize(query: "report", results: results)
        #expect(result != nil)
        #expect(!result!.isEmpty)
    }

    // MARK: - Caching: second call returns cached result

    @Test("Second identical query returns cached result without calling provider again")
    func cachesIdenticalQuery() async {
        let provider = MockSummarizerProvider(response: "Summary here.")
        let summarizer = ResultSummarizer(provider: provider)
        let results = [makeSummary(name: "file.txt")]

        let first = await summarizer.summarize(query: "test", results: results)
        let second = await summarizer.summarize(query: "test", results: results)

        #expect(first == second)
        // Provider should only have been called once
        #expect(provider.callCount == 1)
    }

    // MARK: - Provider error returns nil

    @Test("Provider error returns nil")
    func providerErrorReturnsNil() async {
        let provider = MockSummarizerProvider(response: nil) // will throw
        let summarizer = ResultSummarizer(provider: provider)
        let results = [makeSummary(name: "file.txt")]
        let result = await summarizer.summarize(query: "test", results: results)
        #expect(result == nil)
    }
}

// MARK: - Helpers

private func makeSummary(name: String) -> FileMetadataSummary {
    FileMetadataSummary(
        name: name,
        path: "~/Documents/\(name)",
        size: 1024,
        modifiedAt: Date(),
        extension: name.split(separator: ".").last.map(String.init),
        localTags: []
    )
}

// MARK: - Mock Provider for ResultSummarizer tests

/// A mock AIModelProvider that returns a canned complete() response or throws.
final class MockSummarizerProvider: AIModelProvider, @unchecked Sendable {
    let name: String = "mock-summarizer"
    let capabilities: Set<AICapability> = [.resultSummary, .querySuggestion]

    private let response: String?
    private(set) var callCount: Int = 0

    /// - Parameter response: The string to yield from complete(). Pass `nil` to simulate an error.
    init(response: String?) {
        self.response = response
    }

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [self] continuation in
            Task { [self] in
                self.callCount += 1
                if let response {
                    continuation.yield(response)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: AIError.notAvailable)
                }
            }
        }
    }

    func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
        return naturalLanguage
    }
}
