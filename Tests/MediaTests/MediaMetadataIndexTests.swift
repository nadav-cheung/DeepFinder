// Tests/MediaTests/MediaMetadataIndexTests.swift
import Testing
import Foundation
import ImageIO
import AppKit
@testable import DeepFinder

@Suite("MediaMetadataIndex")
struct MediaMetadataIndexTests {

    @Test("Store and retrieve metadata for a file")
    func storeAndRetrieve() async {
        let index = MediaMetadataIndex()
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(1920)])
        await index.store(fileID: 1, metadata: meta)
        let retrieved = await index.metadata(for: 1)
        #expect(retrieved?.fields["width"]?.intValue == 1920)
    }

    @Test("Returns nil for unknown file ID")
    func unknownFileReturnsNil() async {
        let index = MediaMetadataIndex()
        let result = await index.metadata(for: 999)
        #expect(result == nil)
    }

    @Test("Remove metadata for a file")
    func removeMetadata() async {
        let index = MediaMetadataIndex()
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: [:])
        await index.store(fileID: 1, metadata: meta)
        await index.remove(fileID: 1)
        let result = await index.metadata(for: 1)
        #expect(result == nil)
    }

    @Test("Extract metadata for supported file")
    func extractForSupportedFile() async {
        let index = MediaMetadataIndex()
        // Create a valid test image
        let url = URL(fileURLWithPath: "/tmp/deepfinder_meta_test.png")
        defer { try? FileManager.default.removeItem(at: url) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil, width: 50, height: 60,
            bitsPerComponent: 8, bytesPerRow: 4 * 50,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else { return }
        guard let cgImage = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)

        let meta = await index.extractAndStore(fileID: 42, url: url, fileExtension: "png")
        #expect(meta != nil)
        #expect(meta?.fields["width"]?.intValue == 50)
        #expect(meta?.fields["height"]?.intValue == 60)

        // Verify stored
        let stored = await index.metadata(for: 42)
        #expect(stored?.fields["width"]?.intValue == 50)
    }

    @Test("Skip unsupported file extension")
    func skipUnsupportedExtension() async {
        let index = MediaMetadataIndex()
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let meta = await index.extractAndStore(fileID: 1, url: url, fileExtension: "txt")
        #expect(meta == nil)
    }

    @Test("Count reflects stored entries")
    func countReflectsStorage() async {
        let index = MediaMetadataIndex()
        #expect(await index.count == 0)

        let meta = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(100)])
        await index.store(fileID: 1, metadata: meta)
        #expect(await index.count == 1)

        await index.store(fileID: 2, metadata: meta)
        #expect(await index.count == 2)

        await index.remove(fileID: 1)
        #expect(await index.count == 1)
    }

    @Test("Overwrite existing metadata for same file ID")
    func overwriteMetadata() async {
        let index = MediaMetadataIndex()
        let meta1 = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(100)])
        let meta2 = ExtractedMetadata(fileExtension: "jpg", fields: ["width": .integer(200)])

        await index.store(fileID: 1, metadata: meta1)
        await index.store(fileID: 1, metadata: meta2)

        let retrieved = await index.metadata(for: 1)
        #expect(retrieved?.fields["width"]?.intValue == 200)
        #expect(await index.count == 1)
    }

    @Test("Custom registry is used for extraction")
    func customRegistry() async {
        let mock = MockExtractor(supportedExtensions: ["xyz"], result: ExtractedMetadata(fileExtension: "xyz", fields: ["custom": .string("value")]))
        let registry = MetadataExtractorRegistry(extractors: [mock])
        let index = MediaMetadataIndex(registry: registry)

        let url = URL(fileURLWithPath: "/tmp/test.xyz")
        let meta = await index.extractAndStore(fileID: 1, url: url, fileExtension: "xyz")
        #expect(meta != nil)
        #expect(meta?.fields["custom"]?.stringValue == "value")
    }

    @Test("Extract and store returns nil for non-existent file")
    func extractNonExistentFile() async {
        let index = MediaMetadataIndex()
        let url = URL(fileURLWithPath: "/tmp/deepfinder_nonexistent_\(UUID().uuidString).jpg")
        let meta = await index.extractAndStore(fileID: 1, url: url, fileExtension: "jpg")
        #expect(meta == nil)
        #expect(await index.count == 0)
    }

    @Test("Remove non-existent file ID is a no-op")
    func removeNonExistent() async {
        let index = MediaMetadataIndex()
        let meta = ExtractedMetadata(fileExtension: "jpg", fields: [:])
        await index.store(fileID: 1, metadata: meta)
        await index.remove(fileID: 999) // should not crash
        #expect(await index.count == 1)
    }
}
