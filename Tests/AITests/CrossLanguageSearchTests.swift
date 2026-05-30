import Foundation
import Testing
@testable import DeepFinder

@Suite("CrossLanguageSearch")
struct CrossLanguageSearchTests {

    // MARK: - Nil provider returns empty array

    @Test("Nil provider returns empty array")
    func nilProviderReturnsEmpty() async {
        let search = CrossLanguageSearch(provider: nil)
        let result = await search.expandQuery("设计稿")
        #expect(result.isEmpty)
    }

    // MARK: - Chinese query returns English synonyms

    @Test("Chinese query returns English synonyms via provider")
    func chineseQueryReturnsEnglishSynonyms() async {
        let provider = MockCrossLanguageProvider(
            response: "mockup, design, prototype, artwork"
        )
        let search = CrossLanguageSearch(provider: provider)
        let result = await search.expandQuery("设计稿")
        #expect(result.count == 4)
        #expect(result.contains("mockup"))
        #expect(result.contains("design"))
        #expect(result.contains("prototype"))
        #expect(result.contains("artwork"))
    }

    // MARK: - English query returns Chinese translations

    @Test("English query returns Chinese translations via provider")
    func englishQueryReturnsChineseTranslations() async {
        let provider = MockCrossLanguageProvider(
            response: "设计稿, 模型, 设计文件"
        )
        let search = CrossLanguageSearch(provider: provider)
        let result = await search.expandQuery("mockup")
        #expect(result.count == 3)
        #expect(result.contains("设计稿"))
        #expect(result.contains("模型"))
        #expect(result.contains("设计文件"))
    }

    // MARK: - Results are cached

    @Test("Identical query hits cache on second call")
    func resultsAreCached() async {
        let provider = MockCrossLanguageProvider(
            response: "design, mockup"
        )
        let search = CrossLanguageSearch(provider: provider)

        // First call: hits provider
        let result1 = await search.expandQuery("设计稿")
        #expect(result1 == ["design", "mockup"])
        #expect(provider.callCount == 1)

        // Second call: should be cached, no additional provider call
        let result2 = await search.expandQuery("设计稿")
        #expect(result2 == ["design", "mockup"])
        #expect(provider.callCount == 1)
    }

    // MARK: - Different queries are cached independently

    @Test("Different queries cached independently")
    func differentQueriesCachedIndependently() async {
        let provider = MockCrossLanguageProvider(
            response: "design, mockup"
        )
        let search = CrossLanguageSearch(provider: provider)

        let result1 = await search.expandQuery("设计稿")
        #expect(result1 == ["design", "mockup"])

        // Change provider response for the next call
        provider.response = "合同, 协议"
        let result2 = await search.expandQuery("contract")
        #expect(result2 == ["合同", "协议"])
        #expect(provider.callCount == 2)
    }

    // MARK: - Provider error returns empty array

    @Test("Provider error returns empty array")
    func providerErrorReturnsEmpty() async {
        let provider = MockCrossLanguageProvider(response: nil)
        let search = CrossLanguageSearch(provider: provider)
        let result = await search.expandQuery("设计稿")
        #expect(result.isEmpty)
    }

    // MARK: - Empty provider response returns empty array

    @Test("Empty provider response returns empty array")
    func emptyProviderResponseReturnsEmpty() async {
        let provider = MockCrossLanguageProvider(response: "   ")
        let search = CrossLanguageSearch(provider: provider)
        let result = await search.expandQuery("设计稿")
        #expect(result.isEmpty)
    }

    // MARK: - Sendable conformance

    @Test("CrossLanguageSearch is Sendable")
    func searchIsSendable() {
        let search = CrossLanguageSearch(provider: nil)
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(search)
    }
}

// MARK: - Mock Provider for CrossLanguageSearch tests

final class MockCrossLanguageProvider: AIModelProvider, @unchecked Sendable {
    let name: String = "mock-crosslang"
    let capabilities: Set<AICapability> = [.intentAnalysis]

    var response: String?
    private(set) var callCount: Int = 0

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
