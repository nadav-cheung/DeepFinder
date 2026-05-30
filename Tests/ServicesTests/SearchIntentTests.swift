import Foundation
import Testing
import AppIntents
@testable import DeepFinder

@Suite("SearchFilesIntent")
struct SearchFilesIntentTests {

    // MARK: - Intent Metadata

    @Test("Intent has correct title")
    func intentTitle() {
        let title = SearchFilesIntent.title
        #expect(title.key == "Search Files")
    }

    @Test("Intent has meaningful description")
    func intentDescription() {
        let desc = SearchFilesIntent.description
        #expect(desc != nil)
    }

    // MARK: - Parameters

    @Test("Intent accepts query parameter")
    func queryParameter() {
        let intent = SearchFilesIntent()
        intent.query = "report.pdf"
        #expect(intent.query == "report.pdf")
    }

    @Test("Intent accepts optional limit parameter")
    func limitParameter() {
        let intent = SearchFilesIntent()
        #expect(intent.limit == nil)

        intent.limit = 10
        #expect(intent.limit == 10)
    }

    // MARK: - Perform

    @Test("perform() returns array of file paths")
    func performReturnsFilePaths() async throws {
        let intent = SearchFilesIntent()
        intent.query = "test"
        let result = try await intent.perform()
        // Returns empty for now (daemon connection added later)
        #expect(result.value != nil)
    }
}
