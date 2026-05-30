// Sources/Media/MetadataExtractor.swift
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
