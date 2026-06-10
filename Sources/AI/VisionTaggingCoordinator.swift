// Sources/AI/VisionTaggingCoordinator.swift
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

/// Coordinates background Vision tagging for image files discovered during indexing.
///
/// Processes image files in batches using `LocalVisionProvider`, with bounded
/// concurrency to avoid saturating the Neural Engine / GPU. Results are returned
/// as `(fileID, ExtractedMetadata?)` pairs ready for persistence.
///
/// **Integration point (IndexingEngine or similar caller):**
/// ```
/// // After FileScanner emits .fileFound records, collect image paths:
/// let imageFiles: [(id: UInt32, url: URL)] = records
///     .filter { LocalVisionProvider.supportedExtensions.contains($0.extension?.lowercased() ?? "") }
///     .map { ($0.id, URL(fileURLWithPath: $0.path)) }
///
/// // Process via coordinator:
/// let coordinator = VisionTaggingCoordinator(config: currentConfig)
/// let tagged = await coordinator.processBatch(imageFiles)
/// for (fileID, metadata) in tagged {
///     if let metadata { mediaIndex.store(fileID: fileID, metadata: metadata) }
/// }
/// ```
///
/// REQ-3.0-10: Wire Vision tags into file scanning pipeline.
public actor VisionTaggingCoordinator {

    /// Maximum number of concurrent Vision analyses.
    public static let defaultMaxConcurrency = 4

    private let provider: LocalVisionProvider
    private let maxConcurrency: Int
    private let localVisionEnabled: Bool

    public init(
        provider: LocalVisionProvider = LocalVisionProvider(),
        maxConcurrency: Int = defaultMaxConcurrency,
        localVisionEnabled: Bool = true
    ) {
        self.provider = provider
        self.maxConcurrency = max(1, maxConcurrency)
        self.localVisionEnabled = localVisionEnabled
    }

    /// Process a batch of image files, returning vision tag metadata for each.
    ///
    /// Files whose analysis returns `nil` (unreadable, unanalyzable, no tags)
    /// produce a `nil` metadata entry so callers can distinguish "processed but
    /// empty" from "not processed".
    ///
    /// - Parameter files: Array of (fileID, URL) pairs for image files.
    /// - Returns: Array of (fileID, ExtractedMetadata?) in the same order as input.
    public func processBatch(_ files: [(id: UInt32, url: URL)]) async -> [(id: UInt32, metadata: ExtractedMetadata?)] {
        guard localVisionEnabled else {
            return files.map { ($0.id, nil) }
        }

        // Build an indexed array so we can preserve order with TaskGroup.
        let indexed: [(index: Int, id: UInt32, url: URL)] = files.enumerated().map { (index, file) in
            (index: index, id: file.id, url: file.url)
        }

        let results = await withTaskGroup(of: (Int, UInt32, ExtractedMetadata?).self) { group in
            // Semaphore-like counter to limit concurrency.
            var submitted = 0
            var iter = indexed.makeIterator()

            // Seed initial batch up to maxConcurrency.
            while submitted < self.maxConcurrency, let item = iter.next() {
                group.addTask {
                    let tags = await self.provider.analyzeImage(at: item.url)
                    let metadata = tags.flatMap { LocalVisionProvider.tagsToMetadata($0) }
                    return (item.index, item.id, metadata)
                }
                submitted += 1
            }

            // As tasks complete, submit more.
            var collected: [(Int, UInt32, ExtractedMetadata?)] = []
            collected.reserveCapacity(files.count)

            while let result = await group.next() {
                collected.append(result)
                if let item = iter.next() {
                    group.addTask {
                        let tags = await self.provider.analyzeImage(at: item.url)
                        let metadata = tags.flatMap { LocalVisionProvider.tagsToMetadata($0) }
                        return (item.index, item.id, metadata)
                    }
                }
            }

            // Sort by original index to preserve input order.
            return collected.sorted { $0.0 < $1.0 }
        }

        return results.map { ($0.1, $0.2) }
    }
}
