// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
import DeepFinderIndex
@testable import DeepFinderMedia

@Suite("MetadataLoader")
struct MetadataLoaderTests {

    // MARK: - Test doubles

    /// Actor-backed recorder so extraction call counts are safe across async calls.
    private actor CallRecorder {
        private(set) var paths: [String] = []
        func record(_ path: String) { paths.append(path) }
        var count: Int { paths.count }
    }

    /// Extractor stub that records each call and returns a canned result.
    private struct RecordingExtractor: MetadataExtractor, Sendable {
        let supportedExtensions: Set<String>
        let recorder: CallRecorder
        let result: ExtractedMetadata
        func extract(url: URL) async -> ExtractedMetadata? {
            await recorder.record(url.path)
            return result
        }
    }

    /// Build a loader wired to a recording extractor over the given extensions.
    private func makeLoader(
        extensions exts: Set<String> = ["jpg"],
        recorder: CallRecorder
    ) -> (loader: MetadataLoader, canned: ExtractedMetadata) {
        let canned = ExtractedMetadata(
            fileExtension: "jpg",
            fields: ["width": .integer(640), "height": .integer(480)]
        )
        let registry = MetadataExtractorRegistry(extractors: [
            RecordingExtractor(supportedExtensions: exts, recorder: recorder, result: canned)
        ])
        return (MetadataLoader(registry: registry), canned)
    }

    // MARK: - Extraction

    @Test("metadata(for:) returns extracted fields on first call")
    func returnsExtractedMetadata() async {
        let recorder = CallRecorder()
        let (loader, canned) = makeLoader(recorder: recorder)
        let result = await loader.metadata(for: URL(fileURLWithPath: "/tmp/photo.jpg"), fileExtension: nil)
        #expect(result == canned)
        let count = await recorder.count
        #expect(count == 1)
    }

    @Test("Second call for the same path is served from cache (extractor not called again)")
    func cachesByPath() async {
        let recorder = CallRecorder()
        let (loader, canned) = makeLoader(recorder: recorder)
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        _ = await loader.metadata(for: url, fileExtension: nil)
        let cached = await loader.metadata(for: url, fileExtension: nil)
        #expect(cached == canned)
        let count = await recorder.count
        #expect(count == 1)
    }

    // MARK: - Cache accessors

    @Test("cachedMetadata(forPath:) is nil before extraction and populated after")
    func cachedMetadataAccessor() async {
        let recorder = CallRecorder()
        let (loader, _) = makeLoader(recorder: recorder)
        let path = "/tmp/photo.jpg"
        let before = await loader.cachedMetadata(forPath: path)
        #expect(before == nil)
        _ = await loader.metadata(for: URL(fileURLWithPath: path), fileExtension: nil)
        let after = await loader.cachedMetadata(forPath: path)
        #expect(after != nil)
    }

    @Test("clearCache() evicts entries so the next call re-extracts")
    func clearCacheReextracts() async {
        let recorder = CallRecorder()
        let (loader, _) = makeLoader(recorder: recorder)
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        _ = await loader.metadata(for: url, fileExtension: nil)
        await loader.clearCache()
        _ = await loader.metadata(for: url, fileExtension: nil)
        let count = await recorder.count
        #expect(count == 2)
    }

    // MARK: - Extension resolution

    @Test("metadata(for:) returns nil for unsupported extension without calling the extractor")
    func unsupportedExtension() async {
        let recorder = CallRecorder()
        let (loader, _) = makeLoader(recorder: recorder)
        let result = await loader.metadata(for: URL(fileURLWithPath: "/tmp/data.xyz"), fileExtension: "xyz")
        #expect(result == nil)
        let count = await recorder.count
        #expect(count == 0)
    }

    @Test("metadata(for:) falls back to url.pathExtension when ext is nil or empty")
    func fallsBackToPathExtension() async {
        let recorder = CallRecorder()
        let (loader, canned) = makeLoader(recorder: recorder)
        // nil ext → derive from path
        let r1 = await loader.metadata(for: URL(fileURLWithPath: "/tmp/photo.JPG"), fileExtension: nil)
        #expect(r1 == canned)
        // empty ext → also falls back
        let r2 = await loader.metadata(for: URL(fileURLWithPath: "/tmp/photo2.jpg"), fileExtension: "")
        #expect(r2 == canned)
    }

    // MARK: - Independence

    @Test("Different paths are extracted independently")
    func independentPaths() async {
        let recorder = CallRecorder()
        let (loader, _) = makeLoader(recorder: recorder)
        _ = await loader.metadata(for: URL(fileURLWithPath: "/tmp/a.jpg"), fileExtension: nil)
        _ = await loader.metadata(for: URL(fileURLWithPath: "/tmp/b.jpg"), fileExtension: nil)
        let count = await recorder.count
        #expect(count == 2)
    }

    // MARK: - Default registry factory

    @Test("MetadataExtractorRegistry.default supports image, audio, video, and PDF extensions")
    func defaultRegistryCoversCoreTypes() {
        let exts = MetadataExtractorRegistry.default.allSupportedExtensions
        #expect(exts.contains("jpg"))
        #expect(exts.contains("png"))
        #expect(exts.contains("mp3"))
        #expect(exts.contains("mp4"))
        #expect(exts.contains("pdf"))
    }
}
