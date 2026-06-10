// Tests/MediaTests/MetadataFilterTests.swift
import Testing
import Foundation
import DeepFinderIndex
import DeepFinderSearch
@testable import DeepFinderMedia

@Suite("Metadata Filters")
struct MetadataFilterTests {

    private func makeFile(
        id: UInt32 = 1,
        name: String = "photo.jpg",
        ext: String? = "jpg",
        metadata: ExtractedMetadata? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: "/Users/test/\(name)",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 1024,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: ext,
            metadata: metadata
        )
    }

    private func makeResult(_ file: FileRecord) -> SearchResult {
        SearchResult(record: file, providerID: "test", score: 1.0, matchType: .substring)
    }

    // MARK: - Width/Height

    @Test("metadataMin matches width >= threshold")
    func metadataMinWidth() {
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(3840)])
        let file = makeFile(metadata: meta)
        let filter = SearchFilter.metadataMin("width", 2560)
        #expect(filter.matches(file))
    }

    @Test("metadataMin rejects width below threshold")
    func metadataMinWidthRejects() {
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(1920)])
        let file = makeFile(metadata: meta)
        let filter = SearchFilter.metadataMin("width", 2560)
        #expect(!filter.matches(file))
    }

    @Test("metadataMax matches duration <= threshold")
    func metadataMaxDuration() {
        let meta = ExtractedMetadata(fileExtension: "mp3", fields: ["duration": .double(180.0)])
        let file = makeFile(name: "song.mp3", ext: "mp3", metadata: meta)
        let filter = SearchFilter.metadataMax("duration", 300)
        #expect(filter.matches(file))
    }

    @Test("metadataMatch matches string field substring")
    func metadataMatchArtist() {
        let meta = ExtractedMetadata(fileExtension: "mp3", fields: ["artist": .string("周杰伦")])
        let file = makeFile(name: "song.mp3", ext: "mp3", metadata: meta)
        let filter = SearchFilter.metadataMatch("artist", "周")
        #expect(filter.matches(file))
    }

    @Test("metadataMatch rejects missing field")
    func metadataMatchRejectsMissing() {
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(100)])
        let file = makeFile(metadata: meta)
        let filter = SearchFilter.metadataMatch("artist", "test")
        #expect(!filter.matches(file))
    }

    @Test("File without metadata fails metadata filter")
    func noMetadataFailsFilter() {
        let file = makeFile(metadata: nil)
        let filter = SearchFilter.metadataMin("width", 100)
        #expect(!filter.matches(file))
    }

    @Test("metadataRange matches value in range")
    func metadataRangeWidth() {
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(1920)])
        let file = makeFile(metadata: meta)
        let filter = SearchFilter.metadataRange("width", 1000...2000)
        #expect(filter.matches(file))
    }

    @Test("metadataRange rejects value outside range")
    func metadataRangeRejectsOutside() {
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(3840)])
        let file = makeFile(metadata: meta)
        let filter = SearchFilter.metadataRange("width", 1000...2000)
        #expect(!filter.matches(file))
    }

    // MARK: - FilterPipeline integration

    @Test("FilterPipeline parses width:>2560")
    func pipelineWidthFilter() {
        let pipeline = FilterPipeline.parse(from: [(key: "width", value: ">2560")])
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(3840)])
        let results = pipeline.apply(to: [makeResult(makeFile(metadata: meta))])
        #expect(results.count == 1)
    }

    @Test("FilterPipeline parses artist:周杰伦")
    func pipelineArtistFilter() {
        let pipeline = FilterPipeline.parse(from: [(key: "artist", value: "周杰伦")])
        let meta = ExtractedMetadata(fileExtension: "mp3", fields: ["artist": .string("周杰伦")])
        let results = pipeline.apply(to: [makeResult(makeFile(name: "song.mp3", ext: "mp3", metadata: meta))])
        #expect(results.count == 1)
    }

    @Test("FilterPipeline parses duration:>300")
    func pipelineDurationFilter() {
        let pipeline = FilterPipeline.parse(from: [(key: "duration", value: ">300")])
        let meta = ExtractedMetadata(fileExtension: "mp4", fields: ["duration": .double(600.0)])
        let results = pipeline.apply(to: [makeResult(makeFile(name: "video.mp4", ext: "mp4", metadata: meta))])
        #expect(results.count == 1)
    }

    @Test("FilterPipeline parses pages:>50")
    func pipelinePagesFilter() {
        let pipeline = FilterPipeline.parse(from: [(key: "pages", value: ">50")])
        let meta = ExtractedMetadata(fileExtension: "pdf", fields: ["pageCount": .integer(120)])
        let results = pipeline.apply(to: [makeResult(makeFile(name: "doc.pdf", ext: "pdf", metadata: meta))])
        #expect(results.count == 1)
    }

    @Test("FilterPipeline metadata filter rejects non-matching")
    func pipelineMetadataRejects() {
        let pipeline = FilterPipeline.parse(from: [(key: "width", value: ">2560")])
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(100)])
        let results = pipeline.apply(to: [makeResult(makeFile(metadata: meta))])
        #expect(results.isEmpty)
    }
}
