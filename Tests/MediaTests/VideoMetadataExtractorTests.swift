// Tests/MediaTests/VideoMetadataExtractorTests.swift
import Testing
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
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

    @Test("Extract returns nil for zero-byte file")
    func zeroByteFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_empty_\(UUID().uuidString).mp4")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Supported extensions exclude non-video formats")
    func supportedExtensionsExcludeNonVideo() {
        let exts = extractor.supportedExtensions
        #expect(!exts.contains("mp3"))
        #expect(!exts.contains("jpg"))
        #expect(!exts.contains("pdf"))
    }

    // MARK: - Happy-path tests

    @Test("Extract metadata from valid MP4 video file")
    func extractFromValidMp4() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_video_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        try await createTestMP4(at: url, width: 320, height: 240, fps: 30, frameCount: 30)

        let result = await extractor.extract(url: url)
        #expect(result != nil, "Should extract metadata from valid MP4")
        #expect(result?.fileExtension == "mp4")

        // Duration should be approximately 1 second (30 frames / 30 fps)
        if let duration = result?.fields["duration"]?.doubleValue {
            #expect(duration > 0.5 && duration < 2.0, "Duration should be ~1.0s, got \(duration)")
        }

        // Resolution
        if let width = result?.fields["width"]?.intValue {
            #expect(width == 320, "Width should be 320, got \(width)")
        }
        if let height = result?.fields["height"]?.intValue {
            #expect(height == 240, "Height should be 240, got \(height)")
        }

        // FPS
        if let fps = result?.fields["fps"]?.doubleValue {
            #expect(fps > 0, "FPS should be positive, got \(fps)")
        }

        // Codec should be present (H.264 typically)
        #expect(result?.fields["codec"] != nil, "Should have codec field")
    }

    @Test("Extract metadata from HD resolution video")
    func extractFromHdVideo() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_hd_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        try await createTestMP4(at: url, width: 1280, height: 720, fps: 24, frameCount: 12)

        let result = await extractor.extract(url: url)
        #expect(result != nil, "Should extract metadata from HD video")

        if let width = result?.fields["width"]?.intValue {
            #expect(width == 1280, "Width should be 1280, got \(width)")
        }
        if let height = result?.fields["height"]?.intValue {
            #expect(height == 720, "Height should be 720, got \(height)")
        }
    }
}

// MARK: - Test Fixture Helpers

/// Creates a valid MP4 video file with solid-color frames.
/// Uses AVAssetWriter with a DispatchGroup to coordinate the async writing.
private func createTestMP4(
    at url: URL,
    width: Int,
    height: Int,
    fps: Int,
    frameCount: Int
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        writeMP4Sync(at: url, width: width, height: height, fps: fps, frameCount: frameCount) { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

private func writeMP4Sync(
    at url: URL,
    width: Int,
    height: Int,
    fps: Int,
    frameCount: Int,
    completion: @escaping (Error?) -> Void
) {
    let outputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]

    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    } catch {
        completion(error)
        return
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false
    writer.add(input)

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )

    let lock = NSLock()
    var frameIndex = 0
    let frameSemaphore = DispatchSemaphore(value: 0)
    let writingQueue = DispatchQueue(label: "cn.com.nadav.deepfinder.test.video-writer")

    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    input.requestMediaDataWhenReady(on: writingQueue) {
        while input.isReadyForMoreMediaData {
            lock.lock()
            let idx = frameIndex
            lock.unlock()

            if idx >= frameCount {
                input.markAsFinished()
                frameSemaphore.signal()
                return
            }

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32ARGB,
                nil,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pb = pixelBuffer else {
                input.markAsFinished()
                frameSemaphore.signal()
                return
            }

            // Fill with a solid color (blue in ARGB)
            CVPixelBufferLockBaseAddress(pb, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
                memset(baseAddress, 0xFF, bytesPerRow * height)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            let presentationTime = CMTime(
                value: CMTimeValue(idx),
                timescale: CMTimeScale(fps)
            )
            adaptor.append(pb, withPresentationTime: presentationTime)

            lock.lock()
            frameIndex += 1
            lock.unlock()
        }
    }

    // Wait for all frames to be written
    _ = frameSemaphore.wait(timeout: .now() + 10)

    if writer.status == .writing {
        writer.finishWriting {
            completion(nil)
        }
    } else {
        completion(writer.error)
    }
}
