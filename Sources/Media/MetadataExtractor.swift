// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # Media Module
///
/// Extracts metadata from media files (images, audio, video, PDFs) on demand.
///
/// ## Components
/// - ``MetadataExtractor`` -- protocol for format-specific metadata extractors
/// - ``MetadataExtractorRegistry`` -- dispatcher that routes files to the correct extractor by extension
/// - ``MetadataLoader`` -- on-demand extractor with a per-path cache, for GUI/preview use
/// - ``ExtractedMetadata`` / ``MetadataValue`` -- polymorphic metadata storage types (in DeepFinderIndex)
/// - ``ImageMetadataExtractor`` -- dimensions, DPI, color model via ImageIO/CGImageSource
/// - ``AudioMetadataExtractor`` -- duration, bitrate, artist, album via AVFoundation
/// - ``VideoMetadataExtractor`` -- resolution, duration, codec via AVFoundation
/// - ``PDFMetadataExtractor`` -- page count, title, author via PDFKit
///
/// ## Extraction model
/// Each extractor declares its supported file extensions and produces an ``ExtractedMetadata``
/// dictionary. The registry builds an extension-to-extractor mapping at init time for O(1)
/// dispatch. Extraction is **on-demand** (via ``MetadataLoader`` when a user inspects a file),
/// not during scanning — this keeps the index fast.
///
/// ## Integration status
/// Metadata loaded here is cached in the ``MetadataLoader`` for display (e.g. the GUI file
/// detail panel). It is **not** persisted to SQLite and **not** queryable through the search
/// filter pipeline, because extractors are not wired into the scan path and
/// `FileRecord.metadata` is never populated. Search-by-metadata (`width:>2560`,
/// `duration:>300`, `artist:Beatles`) is a future milestone requiring scan-time
/// population and indexing.
import Foundation
import DeepFinderIndex

/// Protocol for media metadata extractors.
public protocol MetadataExtractor: Sendable {
    /// File extensions this extractor handles (lowercase, without dot).
    var supportedExtensions: Set<String> { get }

    /// Extract metadata from the file at the given URL.
    /// Returns nil if extraction fails or the file is unsupported/corrupt.
    func extract(url: URL) async -> ExtractedMetadata?
}

/// Registry that manages all metadata extractors and dispatches by file extension.
public struct MetadataExtractorRegistry: Sendable {
    private let extensionMap: [String: MetadataExtractor]

    public init(extractors: [MetadataExtractor]) {
        var map: [String: MetadataExtractor] = [:]
        for extractor in extractors {
            for fileExt in extractor.supportedExtensions {
                map[fileExt.lowercased()] = extractor
            }
        }
        self.extensionMap = map
    }

    /// Find the extractor for a given file extension.
    public func extractor(for fileExtension: String) -> MetadataExtractor? {
        extensionMap[fileExtension.lowercased()]
    }

    /// Extract metadata from a file using the appropriate extractor.
    public func extract(url: URL, extension fileExtension: String) async -> ExtractedMetadata? {
        guard let extractor = extractor(for: fileExtension) else { return nil }
        return await extractor.extract(url: url)
    }

    /// All supported extensions across all extractors.
    public var allSupportedExtensions: Set<String> {
        Set(extensionMap.keys)
    }
}

public extension MetadataExtractorRegistry {
    /// A registry configured with all built-in extractors (image, audio, video, PDF).
    ///
    /// Convenience for callers (``MetadataLoader``, the GUI detail panel) that want
    /// every extractor without assembling the list themselves.
    static var `default`: MetadataExtractorRegistry {
        MetadataExtractorRegistry(extractors: [
            ImageMetadataExtractor(),
            AudioMetadataExtractor(),
            VideoMetadataExtractor(),
            PDFMetadataExtractor(),
        ])
    }
}
