// Tests/AITests/VisionTaggingCoordinatorTests.swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import DeepFinder

@Suite("VisionTaggingCoordinator")
struct VisionTaggingCoordinatorTests {

    // MARK: - Disabled State

    @Test("Disabled coordinator returns nil metadata for all files")
    func disabledReturnsEmpty() async {
        let coordinator = VisionTaggingCoordinator(
            provider: LocalVisionProvider(),
            maxConcurrency: 2,
            localVisionEnabled: false
        )

        let files: [(id: UInt32, url: URL)] = [
            (1, URL(fileURLWithPath: "/tmp/img1.jpg")),
            (2, URL(fileURLWithPath: "/tmp/img2.png")),
        ]

        let results = await coordinator.processBatch(files)
        #expect(results.count == 2)
        #expect(results[0].metadata == nil)
        #expect(results[1].metadata == nil)
    }

    // MARK: - Input Order Preservation

    @Test("processBatch preserves input order")
    func preservesInputOrder() async {
        let coordinator = VisionTaggingCoordinator(
            provider: LocalVisionProvider(),
            maxConcurrency: 2,
            localVisionEnabled: true
        )

        let files: [(id: UInt32, url: URL)] = (0..<5).map { i in
            (UInt32(i), URL(fileURLWithPath: "/tmp/nonexistent_\(i).jpg"))
        }

        let results = await coordinator.processBatch(files)
        #expect(results.count == 5)
        for (i, result) in results.enumerated() {
            #expect(result.id == UInt32(i))
        }
    }

    // MARK: - Empty Input

    @Test("processBatch with empty input returns empty output")
    func emptyBatch() async {
        let coordinator = VisionTaggingCoordinator(
            provider: LocalVisionProvider(),
            maxConcurrency: 4,
            localVisionEnabled: true
        )

        let results = await coordinator.processBatch([])
        #expect(results.isEmpty)
    }

    // MARK: - Real Image Analysis

    @Test("Real image produces metadata or nil (both valid)")
    func realImageAnalysis() async {
        let url = createTestPNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinator = VisionTaggingCoordinator(
            provider: LocalVisionProvider(),
            maxConcurrency: 2,
            localVisionEnabled: true
        )

        let files: [(id: UInt32, url: URL)] = [(42, url)]
        let results = await coordinator.processBatch(files)

        #expect(results.count == 1)
        #expect(results[0].id == 42)
        // Vision may or may not return tags for a solid-color image.
        // Either outcome is valid; we just verify the coordinator doesn't crash.
        if let metadata = results[0].metadata {
            #expect(metadata.fields["vision_tags"]?.stringValue != nil)
        }
    }

    // MARK: - Large Batch with Non-Existent Files

    @Test("Large batch of non-existent files completes without crash")
    func largeBatchNonExistent() async {
        let coordinator = VisionTaggingCoordinator(
            provider: LocalVisionProvider(),
            maxConcurrency: 2,
            localVisionEnabled: true
        )

        let files: [(id: UInt32, url: URL)] = (0..<20).map { i in
            (UInt32(i), URL(fileURLWithPath: "/tmp/nonexistent_\(i).jpg"))
        }

        let results = await coordinator.processBatch(files)
        #expect(results.count == 20)
        for result in results {
            #expect(result.metadata == nil)
        }
    }

    // MARK: - Mixed Extensions

    @Test("Non-image extensions are passed through (coordinator does not filter)")
    func mixedExtensions() async {
        let coordinator = VisionTaggingCoordinator(
            provider: LocalVisionProvider(),
            maxConcurrency: 2,
            localVisionEnabled: true
        )

        // Coordinator processes whatever it receives; filtering by extension
        // is the caller's responsibility.
        let files: [(id: UInt32, url: URL)] = [
            (1, URL(fileURLWithPath: "/tmp/nonexistent.jpg")),
            (2, URL(fileURLWithPath: "/tmp/nonexistent.pdf")),
            (3, URL(fileURLWithPath: "/tmp/nonexistent.txt")),
        ]

        let results = await coordinator.processBatch(files)
        #expect(results.count == 3)
        // All non-existent, so all nil.
        for result in results {
            #expect(result.metadata == nil)
        }
    }

    // MARK: - Helpers

    private func createTestPNG(width: Int, height: Int) -> URL {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_vision_coord_\(UUID().uuidString).png")

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
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else {
            Issue.record("Failed to create image destination")
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
