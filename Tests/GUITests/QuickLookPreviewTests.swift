import Testing
import Foundation
import DeepFinderIndex
import DeepFinderSearch
@testable import DeepFinderGUILib

// MARK: - QuickLookPreview Tests

@Suite("QuickLookPreview")
struct QuickLookPreviewTests {

    // MARK: - Helpers

    /// Create a fake SearchResult for testing.
    private func makeResult(
        id: UInt32,
        name: String = "test.txt",
        ext: String? = "txt",
        size: Int64 = 1024,
        isDirectory: Bool = false
    ) -> SearchResult {
        SearchResult(
            record: FileRecord(
                id: id,
                name: name,
                originalName: name,
                path: "/tmp/\(name)",
                parentPath: "/tmp",
                isDirectory: isDirectory,
                size: size,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                extension: ext
            ),
            providerID: "test",
            score: 1.0,
            matchType: .substring
        )
    }

    /// Create an array of N fake results.
    private func makeResults(_ count: Int) -> [SearchResult] {
        (0..<UInt32(count)).map { makeResult(id: $0, name: "file\($0).txt") }
    }

    // MARK: - 1. Initial state is closed

    @Test("Initial state is closed with no preview index")
    @MainActor
    func initialStateIsClosed() {
        let state = QuickLookPreviewState()
        #expect(!state.isPreviewOpen)
        #expect(state.previewIndex == nil)
        #expect(state.metadataFallback == nil)
    }

    // MARK: - 2. Open sets index and state

    @Test("Open sets preview index and opens state")
    @MainActor
    func openSetsIndex() {
        let state = QuickLookPreviewState()
        let result = makeResult(id: 1, name: "photo.jpg", ext: "jpg")
        state.open(at: 0, result: result)

        #expect(state.isPreviewOpen)
        #expect(state.previewIndex == 0)
    }

    // MARK: - 3. Close resets state

    @Test("Close resets to initial state")
    @MainActor
    func closeResetsState() {
        let state = QuickLookPreviewState()
        let result = makeResult(id: 1)
        state.open(at: 0, result: result)
        #expect(state.isPreviewOpen)

        state.close()
        #expect(!state.isPreviewOpen)
        #expect(state.previewIndex == nil)
        #expect(state.metadataFallback == nil)
    }

    // MARK: - 4. Navigate updates index

    @Test("Navigate updates preview index")
    @MainActor
    func navigateUpdatesIndex() {
        let state = QuickLookPreviewState()
        let results = makeResults(5)
        state.open(at: 0, result: results[0])
        #expect(state.previewIndex == 0)

        state.navigate(to: 2, result: results[2])
        #expect(state.previewIndex == 2)

        state.navigate(to: 4, result: results[4])
        #expect(state.previewIndex == 4)
    }

    // MARK: - 5. Toggle opens when closed, closes when open

    @Test("Toggle opens and closes preview")
    @MainActor
    func toggleOpenClose() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        // Open
        controller.togglePreview(results: results, selectedIndex: 1)
        #expect(controller.isPreviewOpen)
        #expect(controller.previewIndex == 1)

        // Close (toggle again)
        controller.togglePreview(results: results, selectedIndex: 1)
        #expect(!controller.isPreviewOpen)
        #expect(controller.previewIndex == nil)
    }

    // MARK: - 6. Toggle with nil selection does nothing

    @Test("Toggle with nil selection does not open")
    @MainActor
    func toggleNilSelection() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        controller.togglePreview(results: results, selectedIndex: nil)
        #expect(!controller.isPreviewOpen)
    }

    // MARK: - 7. Toggle with out-of-bounds selection does nothing

    @Test("Toggle with out-of-bounds selection does not open")
    @MainActor
    func toggleOutOfBoundsSelection() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        controller.togglePreview(results: results, selectedIndex: 5)
        #expect(!controller.isPreviewOpen)

        controller.togglePreview(results: results, selectedIndex: -1)
        #expect(!controller.isPreviewOpen)
    }

    // MARK: - 8. Navigate down wraps around

    @Test("Navigate down wraps to first item")
    @MainActor
    func navigateDownWraps() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        controller.togglePreview(results: results, selectedIndex: 2)
        #expect(controller.previewIndex == 2)

        let newIndex = controller.navigatePreview(results: results, direction: .down)
        #expect(newIndex == 0)
        #expect(controller.previewIndex == 0)
    }

    // MARK: - 9. Navigate up wraps around

    @Test("Navigate up wraps to last item")
    @MainActor
    func navigateUpWraps() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        controller.togglePreview(results: results, selectedIndex: 0)
        #expect(controller.previewIndex == 0)

        let newIndex = controller.navigatePreview(results: results, direction: .up)
        #expect(newIndex == 2)
        #expect(controller.previewIndex == 2)
    }

    // MARK: - 10. Navigate returns nil when preview is closed

    @Test("Navigate returns nil when preview is closed")
    @MainActor
    func navigateReturnsNilWhenClosed() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        let result = controller.navigatePreview(results: results, direction: .down)
        #expect(result == nil)
    }

    // MARK: - 11. Navigate returns nil when results are empty

    @Test("Navigate returns nil when results are empty")
    @MainActor
    func navigateReturnsNilWhenEmpty() {
        let controller = QuickLookPreviewController()

        // Open with a single result then navigate with empty results
        let results = [makeResult(id: 0)]
        controller.togglePreview(results: results, selectedIndex: 0)
        #expect(controller.isPreviewOpen)

        let result = controller.navigatePreview(results: [], direction: .down)
        #expect(result == nil)
    }

    // MARK: - 12. Close resets state via controller

    @Test("Close via controller resets state")
    @MainActor
    func closeViaController() {
        let controller = QuickLookPreviewController()
        let results = makeResults(3)

        controller.togglePreview(results: results, selectedIndex: 1)
        #expect(controller.isPreviewOpen)

        controller.closePreview()
        #expect(!controller.isPreviewOpen)
        #expect(controller.previewIndex == nil)
    }

    // MARK: - 13. Previewable file extensions recognized

    @Test("Common image extensions are previewable")
    func imageExtensionsPreviewable() {
        let jpg = makeResult(id: 0, name: "photo.jpg", ext: "jpg")
        let png = makeResult(id: 1, name: "image.png", ext: "png")
        let gif = makeResult(id: 2, name: "anim.gif", ext: "gif")
        let heic = makeResult(id: 3, name: "photo.heic", ext: "heic")

        #expect(QuickLookPreviewController.isPreviewable(jpg.record))
        #expect(QuickLookPreviewController.isPreviewable(png.record))
        #expect(QuickLookPreviewController.isPreviewable(gif.record))
        #expect(QuickLookPreviewController.isPreviewable(heic.record))
    }

    // MARK: - 14. Document extensions are previewable

    @Test("Document extensions are previewable")
    func documentExtensionsPreviewable() {
        let pdf = makeResult(id: 0, name: "doc.pdf", ext: "pdf")
        let txt = makeResult(id: 1, name: "readme.txt", ext: "txt")
        let md = makeResult(id: 2, name: "README.md", ext: "md")
        let html = makeResult(id: 3, name: "index.html", ext: "html")

        #expect(QuickLookPreviewController.isPreviewable(pdf.record))
        #expect(QuickLookPreviewController.isPreviewable(txt.record))
        #expect(QuickLookPreviewController.isPreviewable(md.record))
        #expect(QuickLookPreviewController.isPreviewable(html.record))
    }

    // MARK: - 15. Audio and video extensions are previewable

    @Test("Audio and video extensions are previewable")
    func mediaExtensionsPreviewable() {
        let mp3 = makeResult(id: 0, name: "song.mp3", ext: "mp3")
        let wav = makeResult(id: 1, name: "audio.wav", ext: "wav")
        let mp4 = makeResult(id: 2, name: "video.mp4", ext: "mp4")
        let mov = makeResult(id: 3, name: "clip.mov", ext: "mov")

        #expect(QuickLookPreviewController.isPreviewable(mp3.record))
        #expect(QuickLookPreviewController.isPreviewable(wav.record))
        #expect(QuickLookPreviewController.isPreviewable(mp4.record))
        #expect(QuickLookPreviewController.isPreviewable(mov.record))
    }

    // MARK: - 16. Unknown extensions are not previewable

    @Test("Unknown extensions are not previewable")
    func unknownExtensionsNotPreviewable() {
        let bin = makeResult(id: 0, name: "data.bin", ext: "bin")
        let dat = makeResult(id: 1, name: "file.dat", ext: "dat")
        let dmg = makeResult(id: 2, name: "disk.dmg", ext: "dmg")
        let iso = makeResult(id: 3, name: "image.iso", ext: "iso")

        #expect(!QuickLookPreviewController.isPreviewable(bin.record))
        #expect(!QuickLookPreviewController.isPreviewable(dat.record))
        #expect(!QuickLookPreviewController.isPreviewable(dmg.record))
        #expect(!QuickLookPreviewController.isPreviewable(iso.record))
    }

    // MARK: - 17. No extension is not previewable

    @Test("No extension is not previewable")
    func noExtensionNotPreviewable() {
        let noExt = makeResult(id: 0, name: "Makefile", ext: nil)
        #expect(!QuickLookPreviewController.isPreviewable(noExt.record))
    }

    // MARK: - 18. Case-insensitive extension check

    @Test("Extension check is case-insensitive")
    func extensionCheckCaseInsensitive() {
        let upper = makeResult(id: 0, name: "photo.JPG", ext: "JPG")
        let mixed = makeResult(id: 1, name: "doc.Pdf", ext: "Pdf")

        #expect(QuickLookPreviewController.isPreviewable(upper.record))
        #expect(QuickLookPreviewController.isPreviewable(mixed.record))
    }

    // MARK: - 19. Metadata fallback for unsupported types

    @Test("Metadata fallback shown for unsupported types")
    @MainActor
    func metadataFallbackForUnsupported() {
        let state = QuickLookPreviewState()
        let bin = makeResult(id: 0, name: "data.bin", ext: "bin", size: 4096)
        state.open(at: 0, result: bin)

        #expect(state.metadataFallback != nil)
        #expect(state.metadataFallback?.filename == "data.bin")
        #expect(state.metadataFallback?.size == 4096)
        #expect(state.metadataFallback?.path == "/tmp/data.bin")
    }

    // MARK: - 20. No metadata fallback for supported types

    @Test("No metadata fallback for supported types")
    @MainActor
    func noMetadataFallbackForSupported() {
        let state = QuickLookPreviewState()
        let jpg = makeResult(id: 0, name: "photo.jpg", ext: "jpg")
        state.open(at: 0, result: jpg)

        #expect(state.metadataFallback == nil)
    }

    // MARK: - 21. Metadata fallback cleared on navigate to supported type

    @Test("Metadata fallback cleared when navigating to supported type")
    @MainActor
    func metadataFallbackClearedOnNavigate() {
        let state = QuickLookPreviewState()
        let bin = makeResult(id: 0, name: "data.bin", ext: "bin")
        let jpg = makeResult(id: 1, name: "photo.jpg", ext: "jpg")

        state.open(at: 0, result: bin)
        #expect(state.metadataFallback != nil)

        state.navigate(to: 1, result: jpg)
        #expect(state.metadataFallback == nil)
    }

    // MARK: - 22. Metadata fallback set when navigating to unsupported type

    @Test("Metadata fallback set when navigating to unsupported type")
    @MainActor
    func metadataFallbackSetOnNavigateToUnsupported() {
        let state = QuickLookPreviewState()
        let jpg = makeResult(id: 0, name: "photo.jpg", ext: "jpg")
        let bin = makeResult(id: 1, name: "data.bin", ext: "bin", size: 8192)

        state.open(at: 0, result: jpg)
        #expect(state.metadataFallback == nil)

        state.navigate(to: 1, result: bin)
        #expect(state.metadataFallback != nil)
        #expect(state.metadataFallback?.filename == "data.bin")
        #expect(state.metadataFallback?.size == 8192)
    }

    // MARK: - 23. Metadata fallback cleared on close

    @Test("Metadata fallback cleared on close")
    @MainActor
    func metadataFallbackClearedOnClose() {
        let state = QuickLookPreviewState()
        let bin = makeResult(id: 0, name: "data.bin", ext: "bin")
        state.open(at: 0, result: bin)
        #expect(state.metadataFallback != nil)

        state.close()
        #expect(state.metadataFallback == nil)
    }

    // MARK: - 24. Navigation updates results array

    @Test("Navigate updates results correctly")
    @MainActor
    func navigateUpdatesResults() {
        let controller = QuickLookPreviewController()
        let results1 = makeResults(5)
        let results2 = (0..<3).map { makeResult(id: UInt32($0), name: "new\($0).swift", ext: "swift") }

        controller.togglePreview(results: results1, selectedIndex: 0)
        #expect(controller.previewIndex == 0)

        // Navigate with a different results array
        let newIndex = controller.navigatePreview(results: results2, direction: .down)
        #expect(newIndex == 1)
        #expect(controller.previewIndex == 1)
    }
}
