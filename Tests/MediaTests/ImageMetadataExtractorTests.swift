// Tests/MediaTests/ImageMetadataExtractorTests.swift
import Testing
import Foundation
import ImageIO
@testable import DeepFinder

@Suite("ImageMetadataExtractor")
struct ImageMetadataExtractorTests {

    private let extractor = ImageMetadataExtractor()

    @Test("Supported extensions include common image formats")
    func supportedExtensions() {
        let exts = extractor.supportedExtensions
        #expect(exts.contains("jpg"))
        #expect(exts.contains("jpeg"))
        #expect(exts.contains("png"))
        #expect(exts.contains("heic"))
        #expect(exts.contains("gif"))
        #expect(exts.contains("tiff"))
        #expect(exts.contains("bmp"))
        #expect(exts.contains("webp"))
    }

    @Test("Extract returns nil for non-existent file")
    func nonExistentFileReturns() async {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_nonexistent_\(UUID().uuidString).jpg")
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Extract returns nil for corrupt file")
    func corruptFileReturns() async throws {
        // Write garbage bytes to a temp file with .jpg extension
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_corrupt_\(UUID().uuidString).jpg")
        try Data("not a real image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Extract metadata from valid PNG file")
    func extractFromValidPng() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_valid_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        // Create a valid PNG using CGContext + CGImageDestination
        let width = 100
        let height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 4 * width,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            #expect(Bool(false), "Failed to create CGContext")
            return
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            #expect(Bool(false), "Failed to create CGImage")
            return
        }

        // Write PNG via CGImageDestination
        let uti = "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            #expect(Bool(false), "Failed to create CGImageDestination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            #expect(Bool(false), "Failed to finalize PNG")
            return
        }

        let result = await extractor.extract(url: url)
        #expect(result != nil)
        #expect(result?.fields["width"]?.intValue == width)
        #expect(result?.fields["height"]?.intValue == height)
    }
}
