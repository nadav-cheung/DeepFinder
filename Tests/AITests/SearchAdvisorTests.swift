import Foundation
import Testing
@testable import DeepFinder

@Suite("SearchAdvisor")
struct SearchAdvisorTests {

    // MARK: - Nil provider returns nil

    @Test("Nil provider returns nil")
    func nilProviderReturnsNil() async {
        let advisor = SearchAdvisor(provider: nil)
        let results = [makeAdvisorSummary(name: "report.pdf")]
        let result = await advisor.suggest(query: "report", results: results)
        #expect(result == nil)
    }

    // MARK: - Returns a string suggestion

    @Test("Returns a suggestion string")
    func returnsSuggestion() async {
        let provider = MockAdvisorProvider(response: "Try ext:xlsx dm:thisyear for quarterly reports.")
        let advisor = SearchAdvisor(provider: provider)
        let results = [makeAdvisorSummary(name: "report.pdf")]
        let result = await advisor.suggest(query: "report", results: results)
        #expect(result != nil)
        #expect(!result!.isEmpty)
    }

    // MARK: - Provider error returns nil

    @Test("Provider error returns nil")
    func providerErrorReturnsNil() async {
        let provider = MockAdvisorProvider(response: nil)
        let advisor = SearchAdvisor(provider: provider)
        let results = [makeAdvisorSummary(name: "file.txt")]
        let result = await advisor.suggest(query: "test", results: results)
        #expect(result == nil)
    }

    // MARK: - Empty results still returns suggestion (AI can suggest from query alone)

    @Test("Empty results still asks provider for suggestion")
    func emptyResultsStillSuggests() async {
        let provider = MockAdvisorProvider(response: "Try ext:pdf")
        let advisor = SearchAdvisor(provider: provider)
        let result = await advisor.suggest(query: "report", results: [])
        #expect(result != nil)
    }

    // MARK: - Sendable conformance

    @Test("SearchAdvisor is Sendable")
    func advisorIsSendable() {
        let advisor = SearchAdvisor(provider: nil)
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(advisor)
    }
}

// MARK: - Helpers

private func makeAdvisorSummary(name: String) -> FileMetadataSummary {
    FileMetadataSummary(
        name: name,
        path: "~/Documents/\(name)",
        size: 1024,
        modifiedAt: Date(),
        extension: name.split(separator: ".").last.map(String.init),
        localTags: []
    )
}

// MARK: - Mock Provider for SearchAdvisor tests

final class MockAdvisorProvider: AIModelProvider, @unchecked Sendable {
    let name: String = "mock-advisor"
    let capabilities: Set<AICapability> = [.querySuggestion]

    private let response: String?

    init(response: String?) {
        self.response = response
    }

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [self] continuation in
            Task { [self] in
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
