// Tests/MediaTests/MetadataExtractorRegistryTests.swift
import Testing
import Foundation
import DeepFinderIndex
@testable import DeepFinderMedia

@Suite("MetadataExtractorRegistry")
struct MetadataExtractorRegistryTests {

    @Test("Registry dispatches by extension")
    func registryDispatchesByExtension() async {
        let mock = MockExtractor(supportedExtensions: ["jpg", "png"], result: ExtractedMetadata(fileExtension: "jpg"))
        let registry = MetadataExtractorRegistry(extractors: [mock])
        let ext = registry.extractor(for: "jpg")
        #expect(ext != nil)
        let ext2 = registry.extractor(for: "png")
        #expect(ext2 != nil)
        let ext3 = registry.extractor(for: "mp3")
        #expect(ext3 == nil)
    }

    @Test("Registry extract returns metadata for supported file")
    func registryExtractsReturns() async throws {
        let expected = ExtractedMetadata(fileExtension: "jpg")
        let mock = MockExtractor(supportedExtensions: ["jpg"], result: expected)
        let registry = MetadataExtractorRegistry(extractors: [mock])
        // Use a temp file for testing
        let url = URL(fileURLWithPath: "/tmp/test_file.jpg")
        let result = await registry.extract(url: url, extension: "jpg")
        // mock returns expected regardless of file existence for unit test
        #expect(result == expected)
    }

    @Test("Registry returns nil for unsupported extension")
    func registryUnsupportedExtension() async {
        let registry = MetadataExtractorRegistry(extractors: [])
        let result = await registry.extract(url: URL(fileURLWithPath: "/tmp/test.xyz"), extension: "xyz")
        #expect(result == nil)
    }

    @Test("Registry is case-insensitive for extensions")
    func registryCaseInsensitive() async {
        let mock = MockExtractor(supportedExtensions: ["jpg"], result: ExtractedMetadata(fileExtension: "jpg"))
        let registry = MetadataExtractorRegistry(extractors: [mock])
        #expect(registry.extractor(for: "JPG") != nil)
        #expect(registry.extractor(for: "Jpg") != nil)
    }

    @Test("Registry allSupportedExtensions aggregates all extractors")
    func allSupportedExtensions() {
        let mock1 = MockExtractor(supportedExtensions: ["jpg", "png"], result: ExtractedMetadata(fileExtension: "jpg"))
        let mock2 = MockExtractor(supportedExtensions: ["mp3", "wav"], result: ExtractedMetadata(fileExtension: "mp3"))
        let registry = MetadataExtractorRegistry(extractors: [mock1, mock2])
        let all = registry.allSupportedExtensions
        #expect(all.contains("jpg"))
        #expect(all.contains("png"))
        #expect(all.contains("mp3"))
        #expect(all.contains("wav"))
        #expect(!all.contains("xyz"))
    }

    @Test("Registry with empty extractors has no supported extensions")
    func emptyRegistry() {
        let registry = MetadataExtractorRegistry(extractors: [])
        #expect(registry.allSupportedExtensions.isEmpty)
        #expect(registry.extractor(for: "jpg") == nil)
    }
}

/// Mock extractor for registry testing.
struct MockExtractor: MetadataExtractor, Sendable {
    let supportedExtensions: Set<String>
    let result: ExtractedMetadata

    func extract(url: URL) async -> ExtractedMetadata? {
        result
    }
}
