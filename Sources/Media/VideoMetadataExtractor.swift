// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

// Sources/Media/VideoMetadataExtractor.swift
import Foundation
import AVFoundation
import CoreMedia
import DeepFinderIndex

/// Extracts metadata from video files using AVFoundation.
public struct VideoMetadataExtractor: MetadataExtractor, Sendable {
    public let supportedExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "wmv", "m4v", "flv", "webm"
    ]

    public func extract(url: URL) async -> ExtractedMetadata? {
        let asset = AVURLAsset(url: url)

        let duration: CMTime
        let tracks: [AVAssetTrack]

        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.load(.tracks)
        } catch {
            return nil
        }

        // Must have at least one video track
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard !videoTracks.isEmpty else { return nil }

        guard duration.isValid && duration.isNumeric else { return nil }

        var meta = ExtractedMetadata(fileExtension: url.pathExtension.lowercased())
        meta.fields["duration"] = .double(CMTimeGetSeconds(duration))

        // Video track properties
        if let videoTrack = videoTracks.first {
            do {
                let size = try await videoTrack.load(.naturalSize)
                meta.fields["width"] = .integer(Int(size.width))
                meta.fields["height"] = .integer(Int(size.height))

                let fps = try await videoTrack.load(.nominalFrameRate)
                meta.fields["fps"] = .double(Double(fps))

                let codecDescriptions = try await videoTrack.load(.formatDescriptions)
                if let desc = codecDescriptions.first {
                    let codecType = CMFormatDescriptionGetMediaSubType(desc)
                    let fourCC = fourCCToString(codecType)
                    meta.fields["codec"] = .string(fourCC)
                }

                let bitrate = try await videoTrack.load(.estimatedDataRate)
                meta.fields["bitRate"] = .integer(Int(bitrate))
            } catch {
                // Partial metadata is acceptable
            }
        }

        // Audio track codec
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        if let audioTrack = audioTracks.first {
            do {
                let codecDescriptions = try await audioTrack.load(.formatDescriptions)
                if let desc = codecDescriptions.first {
                    let codecType = CMFormatDescriptionGetMediaSubType(desc)
                    let fourCC = fourCCToString(codecType)
                    meta.fields["audioCodec"] = .string(fourCC)
                }
            } catch {
                // OK to skip
            }
        }

        return meta
    }

    /// Convert a FourCC code (FourCharCode / UInt32) to a readable string.
    private func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar(truncatingIfNeeded: (code >> 24) & 0xFF),
            CChar(truncatingIfNeeded: (code >> 16) & 0xFF),
            CChar(truncatingIfNeeded: (code >> 8) & 0xFF),
            CChar(truncatingIfNeeded: code & 0xFF),
            0,
        ]
        return String(cString: bytes)
    }
}
