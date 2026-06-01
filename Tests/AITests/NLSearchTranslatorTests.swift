import Foundation
import Testing
@testable import DeepFinder

@Suite("NLSearchTranslator")
struct NLSearchTranslatorTests {

    // MARK: - Nil provider (AI unavailable) falls back to substring

    @Test("Nil provider returns input unchanged")
    func nilProviderReturnsInput() async {
        let translator = NLSearchTranslator(provider: nil)
        let result = await translator.translate("find PDF files modified last week")
        #expect(result == "find PDF files modified last week")
    }

    @Test("Nil provider returns empty string for empty input")
    func nilProviderEmptyInput() async {
        let translator = NLSearchTranslator(provider: nil)
        let result = await translator.translate("")
        #expect(result == "")
    }

    // MARK: - Provider returns translated search syntax

    @Test("Translates 'find PDF files modified last week' to search syntax")
    func translatesPdfLastWeek() async throws {
        let provider = MockNLProvider(translation: "ext:pdf dm:lastweek")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("find PDF files modified last week")
        #expect(result.contains("ext:pdf"))
        #expect(result.contains("dm:"))
    }

    @Test("Translates 'show me videos larger than 100MB' to search syntax")
    func translatesVideosLargeSize() async throws {
        let provider = MockNLProvider(translation: "ext:mp4;mov;mkv;avi size:>100mb")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("show me videos larger than 100MB")
        #expect(result.contains("size:"))
        #expect(result.contains("ext:"))
    }

    @Test("Translates 'documents from today' to search syntax")
    func translatesDocumentsToday() async throws {
        let provider = MockNLProvider(translation: "ext:pdf;doc;docx;xls;xlsx;txt dm:today")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("documents from today")
        #expect(result.contains("dm:"))
    }

    @Test("Translates 'images wider than 1920 pixels' to search syntax")
    func translatesImagesWidth() async throws {
        let provider = MockNLProvider(translation: "ext:jpg;jpeg;png;gif;bmp;svg;width:>1920")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("images wider than 1920 pixels")
        #expect(result.contains("width:"))
    }

    // MARK: - Short / simple queries pass through

    @Test("Short query 'report' returns 'report' (no translation needed)")
    func shortQueryReturnsAsIs() async {
        let provider = MockNLProvider(translation: "report")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("report")
        #expect(result == "report")
    }

    @Test("Empty string returns empty string")
    func emptyStringReturnsEmpty() async {
        let provider = MockNLProvider(translation: "")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("")
        #expect(result == "")
    }

    // MARK: - Already-search-syntax input passes through unchanged

    @Test("Input with ext: modifier is not re-translated")
    func searchSyntaxExtPassthrough() async {
        let provider = MockNLProvider(translation: "should-not-be-used")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("ext:pdf report")
        // Should return input unchanged, not call the provider
        #expect(result == "ext:pdf report")
    }

    @Test("Input with size: modifier is not re-translated")
    func searchSyntaxSizePassthrough() async {
        let provider = MockNLProvider(translation: "should-not-be-used")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("size:>100mb")
        #expect(result == "size:>100mb")
    }

    @Test("Input with dm: modifier is not re-translated")
    func searchSyntaxDmPassthrough() async {
        let provider = MockNLProvider(translation: "should-not-be-used")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("dm:today report")
        #expect(result == "dm:today report")
    }

    @Test("Input with AND operator is not re-translated")
    func searchSyntaxAndPassthrough() async {
        let provider = MockNLProvider(translation: "should-not-be-used")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("report AND budget")
        #expect(result == "report AND budget")
    }

    @Test("Input with OR operator is not re-translated")
    func searchSyntaxOrPassthrough() async {
        let provider = MockNLProvider(translation: "should-not-be-used")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("report|budget")
        #expect(result == "report|budget")
    }

    @Test("Input with path: modifier is not re-translated")
    func searchSyntaxPathPassthrough() async {
        let provider = MockNLProvider(translation: "should-not-be-used")
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("path:Documents report")
        #expect(result == "path:Documents report")
    }

    // MARK: - Provider error falls back to input unchanged

    @Test("Provider error falls back to input unchanged")
    func providerErrorFallsBack() async {
        let provider = MockNLProvider(translation: nil) // will throw
        let translator = NLSearchTranslator(provider: provider)
        let result = await translator.translate("find my files")
        #expect(result == "find my files")
    }
}

// MARK: - Mock Provider for NLSearchTranslator tests

/// A mock AIModelProvider that returns a fixed translation or throws.
final class MockNLProvider: AIModelProvider, @unchecked Sendable {
    let name: String = "mock-nl"
    let capabilities: Set<AICapability> = [.textToSearch]

    private let translation: String?

    /// - Parameter translation: The string to return from translateToSearchSyntax.
    ///   Pass `nil` to simulate an error.
    init(translation: String?) {
        self.translation = translation
    }

    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func translateToSearchSyntax(naturalLanguage: String) async throws -> String {
        guard let translation else {
            throw AIError.notAvailable
        }
        return translation
    }
}
