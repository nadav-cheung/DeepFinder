/// # Media Module
///
/// Extracts, stores, and indexes metadata from media files (images, audio, video, PDFs).
///
/// ## Components
/// - ``MetadataExtractor`` -- protocol for format-specific metadata extractors
/// - ``MetadataExtractorRegistry`` -- dispatcher that routes files to the correct extractor by extension
/// - ``ExtractedMetadata`` / ``MetadataValue`` -- polymorphic metadata storage types
/// - ``MediaMetadataIndex`` -- actor managing in-memory metadata storage
/// - ``ImageMetadataExtractor`` -- extracts dimensions, DPI, color model via ImageIO/CGImageSource
/// - ``AudioMetadataExtractor`` -- extracts duration, bitrate, artist, album via AVFoundation
/// - ``VideoMetadataExtractor`` -- extracts resolution, duration, codec via AVFoundation
/// - ``PDFMetadataExtractor`` -- extracts page count, title, author via PDFKit
///
/// ## Design
/// Each extractor declares its supported file extensions and produces an ``ExtractedMetadata``
/// dictionary. The registry builds an extension-to-extractor mapping at init time for O(1)
/// dispatch. Metadata is persisted to SQLite alongside FileRecords and rebuilt on startup.
///
/// ## Filter Integration
/// Extracted metadata fields are queryable through the search filter pipeline:
/// ```bash
/// deepfinder "width:>2560"          # Images wider than 2560px
/// deepfinder "duration:>300"        # Audio/video longer than 5 minutes
/// deepfinder "artist:Beatles"       # Audio files by artist
/// ```
import Foundation

/// Protocol for media metadata extractors.
protocol MetadataExtractor: Sendable {
    /// File extensions this extractor handles (lowercase, without dot).
    var supportedExtensions: Set<String> { get }

    /// Extract metadata from the file at the given URL.
    /// Returns nil if extraction fails or the file is unsupported/corrupt.
    func extract(url: URL) async -> ExtractedMetadata?
}

/// Registry that manages all metadata extractors and dispatches by file extension.
struct MetadataExtractorRegistry: Sendable {
    private let extractors: [MetadataExtractor]
    private let extensionMap: [String: MetadataExtractor]

    init(extractors: [MetadataExtractor]) {
        self.extractors = extractors
        var map: [String: MetadataExtractor] = [:]
        for extractor in extractors {
            for fileExt in extractor.supportedExtensions {
                map[fileExt.lowercased()] = extractor
            }
        }
        self.extensionMap = map
    }

    /// Find the extractor for a given file extension.
    func extractor(for fileExtension: String) -> MetadataExtractor? {
        extensionMap[fileExtension.lowercased()]
    }

    /// Extract metadata from a file using the appropriate extractor.
    func extract(url: URL, extension fileExtension: String) async -> ExtractedMetadata? {
        guard let extractor = extractor(for: fileExtension) else { return nil }
        return await extractor.extract(url: url)
    }

    /// All supported extensions across all extractors.
    var allSupportedExtensions: Set<String> {
        Set(extensionMap.keys)
    }
}
