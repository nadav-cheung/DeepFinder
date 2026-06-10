import Foundation
import Testing
import AppIntents
import DeepFinderSearch
import DeepFinderAI
import DeepFinderFS
import DeepFinderPersist
import DeepFinderIndex
@testable import DeepFinderServices

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

@Suite("GetFileInfoIntent")
struct GetFileInfoIntentTests {

    // MARK: - Intent Metadata

    @Test("Intent has correct title")
    func intentTitle() {
        let title = GetFileInfoIntent.title
        #expect(title.key == "Get File Info")
    }

    @Test("Intent has meaningful description")
    func intentDescription() {
        let desc = GetFileInfoIntent.description
        #expect(desc != nil)
    }

    // MARK: - Parameters

    @Test("Intent accepts path parameter")
    func pathParameter() {
        let intent = GetFileInfoIntent()
        intent.path = "/Users/test/report.pdf"
        #expect(intent.path == "/Users/test/report.pdf")
    }

    // MARK: - Perform

    @Test("perform() returns a string")
    func performReturnsString() async throws {
        let intent = GetFileInfoIntent()
        intent.path = "/nonexistent/path"
        let result = try await intent.perform()
        // Returns empty string when daemon is unavailable
        #expect(result.value != nil)
    }

    // MARK: - metadataDict

    @Test("metadataDict produces correct dictionary from FileRecord")
    func metadataDictFromRecord() {
        let record = FileRecord(
            id: 1,
            name: "report.pdf",
            originalName: "report.pdf",
            path: "/Users/test/report.pdf",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 4096,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            modifiedAt: Date(timeIntervalSince1970: 1700100000),
            extension: "pdf"
        )
        let dict = GetFileInfoIntent.metadataDict(from: record)
        #expect(dict["name"] == "report.pdf")
        #expect(dict["path"] == "/Users/test/report.pdf")
        #expect(dict["size"] == "4096")
        #expect(dict["isDirectory"] == "false")
        #expect(dict["extension"] == "pdf")
        #expect(dict["createdAt"] != nil)
        #expect(dict["modifiedAt"] != nil)
    }

    @Test("metadataDict omits extension when nil")
    func metadataDictWithoutExtension() {
        let record = FileRecord(
            id: 2,
            name: "makefile",
            originalName: "Makefile",
            path: "/Users/test/Makefile",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 256,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            modifiedAt: Date(timeIntervalSince1970: 1700100000),
            extension: nil
        )
        let dict = GetFileInfoIntent.metadataDict(from: record)
        #expect(dict["extension"] == nil)
        #expect(dict["name"] == "Makefile")
        #expect(dict["isDirectory"] == "false")
    }

    @Test("metadataDict marks directory correctly")
    func metadataDictForDirectory() {
        let record = FileRecord(
            id: 3,
            name: "documents",
            originalName: "Documents",
            path: "/Users/test/Documents",
            parentPath: "/Users/test",
            isDirectory: true,
            size: 0,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            modifiedAt: Date(timeIntervalSince1970: 1700100000),
            extension: nil
        )
        let dict = GetFileInfoIntent.metadataDict(from: record)
        #expect(dict["isDirectory"] == "true")
        #expect(dict["size"] == "0")
    }

    // MARK: - metadataJSON

    @Test("metadataJSON produces valid JSON from FileRecord")
    func metadataJSONFromRecord() {
        let record = FileRecord(
            id: 4,
            name: "photo.jpg",
            originalName: "photo.jpg",
            path: "/Users/test/photo.jpg",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 2048,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            modifiedAt: Date(timeIntervalSince1970: 1700100000),
            extension: "jpg"
        )
        let json = GetFileInfoIntent.metadataJSON(from: record)
        #expect(!json.isEmpty)

        let data = Data(json.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(parsed != nil)
        #expect(parsed?["name"] == "photo.jpg")
        #expect(parsed?["size"] == "2048")
        #expect(parsed?["extension"] == "jpg")
        #expect(parsed?["isDirectory"] == "false")
    }
}
