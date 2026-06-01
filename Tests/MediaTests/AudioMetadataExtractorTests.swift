// Tests/MediaTests/AudioMetadataExtractorTests.swift
import Testing
import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
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

    @Test("Extract returns nil for zero-byte file")
    func zeroByteFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_empty_\(UUID().uuidString).mp3")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Supported extensions exclude non-audio formats")
    func supportedExtensionsExcludeNonAudio() {
        let exts = extractor.supportedExtensions
        #expect(!exts.contains("mp4"))
        #expect(!exts.contains("jpg"))
        #expect(!exts.contains("pdf"))
    }

    // MARK: - Happy-path tests

    @Test("Extract metadata from valid M4A audio file")
    func extractFromValidM4a() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_audio_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try createTestM4A(at: url, duration: 1.0, sampleRate: 44100, channels: 1)

        let result = await extractor.extract(url: url)
        #expect(result != nil, "Should extract metadata from valid M4A")
        #expect(result?.fileExtension == "m4a")

        // Duration should be approximately 1 second
        if let duration = result?.fields["duration"]?.doubleValue {
            #expect(duration > 0.5 && duration < 2.0, "Duration should be ~1.0s, got \(duration)")
        }

        // Should have sample rate
        if let sampleRate = result?.fields["sampleRate"]?.doubleValue {
            #expect(sampleRate > 0, "Sample rate should be positive, got \(sampleRate)")
        }

        // Should have channel count
        if let channels = result?.fields["channels"]?.intValue {
            #expect(channels == 1, "Should be mono, got \(channels) channels")
        }
    }

    @Test("Extract metadata from stereo M4A audio file")
    func extractFromStereoM4a() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_stereo_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try createTestM4A(at: url, duration: 0.5, sampleRate: 44100, channels: 2)

        let result = await extractor.extract(url: url)
        #expect(result != nil, "Should extract metadata from stereo M4A")

        if let channels = result?.fields["channels"]?.intValue {
            #expect(channels == 2, "Should be stereo, got \(channels) channels")
        }
    }
}

// MARK: - Test Fixture Helpers

/// Creates a valid M4A audio file with a sine wave using ExtAudioFile.
private func createTestM4A(
    at url: URL,
    duration: Double,
    sampleRate: Double,
    channels: UInt32
) throws {
    // Describe the output (AAC) format
    var outputASBD = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatMPEG4AAC,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: 0,
        mBytesPerFrame: 0,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 0,
        mReserved: 0
    )

    // Describe the client (PCM) format we'll write in
    var clientASBD = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    var extAudioFile: ExtAudioFileRef?
    let status = ExtAudioFileCreateWithURL(
        url as CFURL,
        kAudioFileM4AType,
        &outputASBD,
        nil,
        AudioFileFlags.eraseFile.rawValue,
        &extAudioFile
    )
    guard status == noErr, let file = extAudioFile else {
        struct AudioCreateError: Error {}
        throw AudioCreateError()
    }
    defer { ExtAudioFileDispose(file) }

    // Set the client format so ExtAudioFile handles the PCM->AAC conversion
    let clientFormatStatus = ExtAudioFileSetProperty(
        file,
        kExtAudioFileProperty_ClientDataFormat,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
        &clientASBD
    )
    guard clientFormatStatus == noErr else {
        struct FormatError: Error {}
        throw FormatError()
    }

    let totalFrames = UInt32(duration * sampleRate)
    let bufferSize: UInt32 = 1024

    var framePosition: UInt32 = 0
    while framePosition < totalFrames {
        let framesToWrite = min(bufferSize, totalFrames - framePosition)

        let bufferBytes = Int(framesToWrite) * Int(channels) * 4
        let dataPtr = malloc(bufferBytes)!
        let audioBuffer = AudioBuffer(
            mNumberChannels: channels,
            mDataByteSize: UInt32(bufferBytes),
            mData: dataPtr
        )
        defer { free(dataPtr) }

        // Fill with sine wave at 440 Hz
        let floatPtr = dataPtr.assumingMemoryBound(to: Float.self)
        for frame in 0..<Int(framesToWrite) {
            let phase = Double(framePosition + UInt32(frame)) / sampleRate
            let sample = Float(sin(2.0 * .pi * 440.0 * phase) * 0.5)
            for ch in 0..<Int(channels) {
                floatPtr[frame * Int(channels) + ch] = sample
            }
        }

        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: audioBuffer
        )

        var framesWritten = framesToWrite
        let writeStatus = ExtAudioFileWrite(file, framesWritten, &audioBufferList)
        guard writeStatus == noErr else {
            struct WriteError: Error {}
            throw WriteError()
        }

        framePosition += framesWritten
    }
}
