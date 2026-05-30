// Sources/Media/MediaMetadataIndex.swift
import Foundation

/// Actor managing media metadata extraction and storage.
///
/// Coordinates metadata extraction for files during indexing.
/// Thread-safe via actor isolation.
actor MediaMetadataIndex {
    private var storage: [UInt32: ExtractedMetadata] = [:]
    private let registry: MetadataExtractorRegistry

    init(registry: MetadataExtractorRegistry? = nil) {
        if let registry {
            self.registry = registry
        } else {
            self.registry = MetadataExtractorRegistry(extractors: [
                ImageMetadataExtractor(),
                AudioMetadataExtractor(),
                VideoMetadataExtractor(),
                PDFMetadataExtractor(),
            ])
        }
    }

    /// Store metadata for a file.
    func store(fileID: UInt32, metadata: ExtractedMetadata) {
        storage[fileID] = metadata
    }

    /// Retrieve metadata for a file.
    func metadata(for fileID: UInt32) -> ExtractedMetadata? {
        storage[fileID]
    }

    /// Remove metadata for a file.
    func remove(fileID: UInt32) {
        storage.removeValue(forKey: fileID)
    }

    /// Extract metadata from a file and store it.
    /// Returns the extracted metadata, or nil if extraction failed or unsupported.
    func extractAndStore(fileID: UInt32, url: URL, fileExtension: String) async -> ExtractedMetadata? {
        guard let meta = await registry.extract(url: url, extension: fileExtension) else {
            return nil
        }
        storage[fileID] = meta
        return meta
    }

    /// Number of files with extracted metadata.
    var count: Int {
        storage.count
    }
}
