import Foundation
import Testing
@testable import DeepFinder

@Suite("FileMetadataSummary")
struct FileMetadataSummaryTests {

    private func makeRecord(
        name: String = "report.pdf",
        path: String = "/Users/nadav/Documents/report.pdf",
        size: Int64 = 2048,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_100),
        extension ext: String? = "pdf"
    ) -> FileRecord {
        FileRecord(
            id: 1,
            name: name,
            originalName: name,
            path: path,
            parentPath: "/Users/nadav/Documents",
            isDirectory: false,
            size: size,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: modifiedAt,
            extension: ext
        )
    }

    @Test("Path anonymization replaces /Users/username/ with ~/")
    func pathAnonymization() {
        let record = makeRecord(path: "/Users/nadav/Documents/report.pdf")
        let summary = FileMetadataSummary.from(record, anonymizePaths: true)
        #expect(summary.path == "~/Documents/report.pdf")
    }

    @Test("Path anonymization with nested username directory")
    func pathAnonymizationNested() {
        let record = makeRecord(path: "/Users/john/projects/code/main.swift")
        let summary = FileMetadataSummary.from(record, anonymizePaths: true)
        #expect(summary.path == "~/projects/code/main.swift")
    }

    @Test("No anonymization when flag is false")
    func noAnonymization() {
        let record = makeRecord(path: "/Users/nadav/Documents/report.pdf")
        let summary = FileMetadataSummary.from(record, anonymizePaths: false)
        #expect(summary.path == "/Users/nadav/Documents/report.pdf")
    }

    @Test("Fields match FileRecord source")
    func fieldsMatchRecord() {
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let record = makeRecord(
            name: "photo.jpg",
            path: "/Users/nadav/Pics/photo.jpg",
            size: 3_000_000,
            modifiedAt: modifiedAt,
            extension: "jpg"
        )
        let summary = FileMetadataSummary.from(record, anonymizePaths: true)

        #expect(summary.name == "photo.jpg")
        #expect(summary.size == 3_000_000)
        #expect(summary.modifiedAt == modifiedAt)
        #expect(summary.extension == "jpg")
    }

    @Test("localTags included in summary")
    func localTagsIncluded() {
        let record = makeRecord()
        let tags = ["sunset", "beach", "vacation"]
        let summary = FileMetadataSummary.from(record, tags: tags, anonymizePaths: true)
        #expect(summary.localTags == tags)
    }

    @Test("localTags default to empty")
    func localTagsDefaultEmpty() {
        let record = makeRecord()
        let summary = FileMetadataSummary.from(record, anonymizePaths: true)
        #expect(summary.localTags.isEmpty)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let record = makeRecord()
        let summary = FileMetadataSummary.from(record, tags: ["tag1"], anonymizePaths: true)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(FileMetadataSummary.self, from: data)

        #expect(decoded == summary)
    }

    @Test("Equality works")
    func equality() {
        let record = makeRecord()
        let a = FileMetadataSummary.from(record, tags: ["x"], anonymizePaths: true)
        let b = FileMetadataSummary.from(record, tags: ["x"], anonymizePaths: true)
        #expect(a == b)
    }

    @Test("Path not starting with /Users/ is unchanged")
    func nonUserPathUnchanged() {
        let record = makeRecord(path: "/Volumes/External/file.txt")
        let summary = FileMetadataSummary.from(record, anonymizePaths: true)
        #expect(summary.path == "/Volumes/External/file.txt")
    }
}
