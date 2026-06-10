// Sources/Media/AudioMetadataExtractor.swift
import Foundation
import AVFoundation
import CoreMedia
import DeepFinderIndex

/// Extracts metadata from audio files using AVFoundation.
public struct AudioMetadataExtractor: MetadataExtractor, Sendable {
    public let supportedExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "wma"
    ]

    public func extract(url: URL) async -> ExtractedMetadata? {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let metadata: [AVMetadataItem]

        do {
            duration = try await asset.load(.duration)
            metadata = try await asset.load(.commonMetadata)
        } catch {
            return nil
        }

        guard duration.isValid && duration.isNumeric else { return nil }

        var meta = ExtractedMetadata(fileExtension: url.pathExtension.lowercased())
        meta.fields["duration"] = .double(CMTimeGetSeconds(duration))

        for item in metadata {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if let value = try? await item.load(.stringValue) {
                    meta.fields["title"] = .string(value)
                }
            case .commonKeyArtist:
                if let value = try? await item.load(.stringValue) {
                    meta.fields["artist"] = .string(value)
                }
            case .commonKeyAlbumName:
                if let value = try? await item.load(.stringValue) {
                    meta.fields["album"] = .string(value)
                }
            case .commonKeyType:
                if let value = try? await item.load(.stringValue) {
                    meta.fields["genre"] = .string(value)
                }
            case .commonKeyCreationDate:
                if let value = try? await item.load(.stringValue), let year = Int(value) {
                    meta.fields["year"] = .integer(year)
                }
            default:
                break
            }
        }

        // Audio track properties
        do {
            let tracks = try await asset.load(.tracks)
            if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
                // Bit rate
                let bitRate = try? await audioTrack.load(.estimatedDataRate)
                if let rate = bitRate {
                    meta.fields["bitRate"] = .integer(Int(rate))
                }

                // Sample rate and channel count from format descriptions
                let formatDescriptions = try? await audioTrack.load(.formatDescriptions)
                if let desc = formatDescriptions?.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    meta.fields["sampleRate"] = .double(asbd.pointee.mSampleRate)
                    meta.fields["channels"] = .integer(Int(asbd.pointee.mChannelsPerFrame))
                }
            }
        } catch {
            // Partial metadata is acceptable
        }

        return meta
    }
}
