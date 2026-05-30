// Tests/AITests/LocalVisionProviderTests.swift
import Testing
import Foundation
import ImageIO
@testable import DeepFinder

@Suite("LocalVisionProvider")
struct LocalVisionProviderTests {

    private let provider = LocalVisionProvider()

    // MARK: - Supported Extensions

    @Test("Supported extensions include jpg, png, heic, gif")
    func supportedExtensions() {
        let exts = LocalVisionProvider.supportedExtensions
        #expect(exts.contains("jpg"))
        #expect(exts.contains("jpeg"))
        #expect(exts.contains("png"))
        #expect(exts.contains("heic"))
        #expect(exts.contains("gif"))
    }

    // MARK: - Analyze Valid Image

    @Test("analyzeImage returns tags for a valid image")
    func analyzeImageReturnsTags() async throws {
        let url = createTestPNG(width: 50, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = await provider.analyzeImage(at: url)
        // VNClassifyImageRequest may return labels or an empty array
        // depending on image content, but should not be nil for a valid image
        #expect(tags != nil)
    }

    // MARK: - Non-existent File

    @Test("analyzeImage returns nil for non-existent file")
    func analyzeImageReturnsNilForNonExistent() async {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_nonexistent_\(UUID().uuidString).jpg")
        let tags = await provider.analyzeImage(at: url)
        #expect(tags == nil)
    }

    // MARK: - Corrupt File

    @Test("analyzeImage returns nil for corrupt file")
    func analyzeImageReturnsNilForCorrupt() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_corrupt_\(UUID().uuidString).jpg")
        try Data("not a real image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tags = await provider.analyzeImage(at: url)
        #expect(tags == nil)
    }

    // MARK: - Tags to Metadata (REQ-3.0-10)

    @Test("tagsToMetadata produces metadata with vision_tags field")
    func testVisionTagsInMetadata() {
        let tags = ["sunset", "beach", "ocean"]
        let metadata = LocalVisionProvider.tagsToMetadata(tags)

        #expect(metadata != nil)
        #expect(metadata?.fields["vision_tags"]?.stringValue == "sunset,beach,ocean")
    }

    @Test("tagsToMetadata returns nil for empty tags array")
    func testEmptyTagsNilMetadata() {
        let metadata = LocalVisionProvider.tagsToMetadata([])
        #expect(metadata == nil)
    }

    // MARK: - Helpers

    private func createTestPNG(width: Int, height: Int) -> URL {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_vision_\(UUID().uuidString).png")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 4 * width,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            Issue.record("Failed to create CGContext")
            return url
        }
        // Fill with a solid color so Vision has something to classify
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            Issue.record("Failed to create CGImage")
            return url
        }

        let uti = "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            Issue.record("Failed to create CGImageDestination")
            return url
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            Issue.record("Failed to finalize PNG")
            return url
        }

        return url
    }
}
