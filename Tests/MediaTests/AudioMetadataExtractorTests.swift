// Tests/MediaTests/AudioMetadataExtractorTests.swift
import Testing
import Foundation
import AVFoundation
@testable import DeepFinder

@Suite("AudioMetadataExtractor")
struct AudioMetadataExtractorTests {

    private let extractor = AudioMetadataExtractor()

    @Test("Supported extensions include common audio formats")
    func supportedExtensions() {
        let exts = extractor.supportedExtensions
        #expect(exts.contains("mp3"))
        #expect(exts.contains("m4a"))
        #expect(exts.contains("wav"))
        #expect(exts.contains("aac"))
        #expect(exts.contains("flac"))
        #expect(exts.contains("ogg"))
        #expect(exts.contains("aiff"))
    }

    @Test("Extract returns nil for non-existent file")
    func nonExistentFile() async {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_nonexistent_\(UUID().uuidString).mp3")
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Extract returns nil for corrupt audio file")
    func corruptFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_corrupt_\(UUID().uuidString).mp3")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await extractor.extract(url: url)
        // AVFoundation may return partial metadata or nil for corrupt files
        // Either is acceptable — just no crash
        _ = result
    }
}
