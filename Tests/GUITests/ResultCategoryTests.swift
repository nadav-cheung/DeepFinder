import Testing
import Foundation
@testable import DeepFinder

@Suite("ResultCategory")
struct ResultCategoryTests {

    // MARK: - Classification

    @Test("Swift files classified as code")
    func testCodeClassification() {
        let result = makeResult(name: "main.swift", ext: "swift")
        #expect(ResultCategory.categorize(result) == .code)
    }

    @Test("Python files classified as code")
    func testPythonClassification() {
        let result = makeResult(name: "script.py", ext: "py")
        #expect(ResultCategory.categorize(result) == .code)
    }

    @Test("PDF classified as document")
    func testDocumentClassification() {
        let result = makeResult(name: "report.pdf", ext: "pdf")
        #expect(ResultCategory.categorize(result) == .documents)
    }

    @Test("PNG classified as image")
    func testImageClassification() {
        let result = makeResult(name: "photo.png", ext: "png")
        #expect(ResultCategory.categorize(result) == .images)
    }

    @Test("MP4 classified as video")
    func testVideoClassification() {
        let result = makeResult(name: "movie.mp4", ext: "mp4")
        #expect(ResultCategory.categorize(result) == .video)
    }

    @Test("MP3 classified as audio")
    func testAudioClassification() {
        let result = makeResult(name: "song.mp3", ext: "mp3")
        #expect(ResultCategory.categorize(result) == .audio)
    }

    @Test("ZIP classified as archive")
    func testArchiveClassification() {
        let result = makeResult(name: "archive.zip", ext: "zip")
        #expect(ResultCategory.categorize(result) == .archives)
    }

    @Test("Unknown extension classified as other")
    func testUnknownClassification() {
        let result = makeResult(name: "data.xyz", ext: "xyz")
        #expect(ResultCategory.categorize(result) == .other)
    }

    @Test("Nil extension classified as other")
    func testNilExtensionClassification() {
        let result = makeResult(name: "Makefile", ext: nil)
        #expect(ResultCategory.categorize(result) == .other)
    }

    // MARK: - Display Properties

    @Test("All cases have non-empty display names and system images")
    func testDisplayProperties() {
        for category in ResultCategory.allCases {
            #expect(!category.displayName.isEmpty, "\(category) has empty displayName")
            #expect(!category.systemImage.isEmpty, "\(category) has empty systemImage")
        }
    }

    @Test("Sort priorities are unique")
    func testSortPrioritiesUnique() {
        let priorities = ResultCategory.allCases.map(\.sortPriority)
        #expect(Set(priorities).count == priorities.count, "Sort priorities must be unique")
    }

    @Test("Code has highest sort priority")
    func testCodeHighestPriority() {
        #expect(ResultCategory.code.sortPriority == 0)
    }

    // MARK: - Helper

    private func makeResult(name: String, ext: String?) -> SearchResult {
        let record = FileRecord(
            id: 1,
            name: name,
            originalName: name,
            path: "/test/\(name)",
            parentPath: "/test",
            isDirectory: false,
            size: 100,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: ext
        )
        return SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
    }
}
