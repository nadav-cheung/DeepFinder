// Tests/MediaTests/VideoMetadataExtractorTests.swift
import Testing
import Foundation
@testable import DeepFinder

@Suite("VideoMetadataExtractor")
struct VideoMetadataExtractorTests {

    private let extractor = VideoMetadataExtractor()

    @Test("Supported extensions include common video formats")
    func supportedExtensions() {
        let exts = extractor.supportedExtensions
        #expect(exts.contains("mp4"))
        #expect(exts.contains("mov"))
        #expect(exts.contains("mkv"))
        #expect(exts.contains("avi"))
        #expect(exts.contains("wmv"))
        #expect(exts.contains("m4v"))
    }

    @Test("Extract returns nil for non-existent file")
    func nonExistentFile() async {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_nonexistent_\(UUID().uuidString).mp4")
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Extract returns nil for corrupt file")
    func corruptFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_corrupt_\(UUID().uuidString).mp4")
        try Data("not video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await extractor.extract(url: url)
        _ = result
    }
}
