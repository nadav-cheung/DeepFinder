/// # Quick Look Preview Module
///
/// Integrates macOS Quick Look (QLPreviewPanel) for file previewing in the
/// search panel. Press Space to open/close preview; arrow keys navigate
/// results while the preview is visible. Unsupported file types show a
/// metadata fallback (filename, size, date).
///
/// ## Components
/// - ``QuickLookPreviewProtocol`` -- protocol abstracting preview actions for testability
/// - ``QuickLookPreviewState`` -- observable state for preview open/close, current index, metadata fallback
/// - ``QuickLookPreviewController`` -- @MainActor controller managing QLPreviewPanel lifecycle
/// - ``PreviewableItem`` -- wraps a SearchResult as a QLPreviewItem
///
/// ## Keyboard Flow
/// 1. User selects a result row (arrow keys)
/// 2. Space toggles preview open/closed
/// 3. While preview is open, arrow keys change the previewed file
/// 4. Escape closes the preview
import AppKit
import Foundation
import Quartz

// MARK: - QuickLookPreviewProtocol

/// Protocol abstracting Quick Look preview actions for testability.
///
/// Production uses `QuickLookPreviewController` which drives QLPreviewPanel.
/// Tests inject `MockQuickLookPreview` to verify toggle/navigation logic
/// without requiring a real panel.
@MainActor
protocol QuickLookPreviewProtocol: Sendable {
    /// Whether the preview panel is currently visible.
    var isPreviewOpen: Bool { get }

    /// Index of the currently previewed result in the results array, or nil.
    var previewIndex: Int? { get }

    /// Metadata fallback text for the currently previewed file.
    /// Non-nil when the file type is not supported by Quick Look.
    var metadataFallback: QuickLookMetadataFallback? { get }

    /// Toggle the preview panel. If opening, previews the file at `index`.
    /// If closing, dismisses the panel.
    func togglePreview(results: [SearchResult], selectedIndex: Int?)

    /// Navigate to the previous or next result while preview is open.
    /// Returns the new selected index, or nil if navigation was not possible.
    func navigatePreview(results: [SearchResult], direction: PreviewNavigationDirection) -> Int?

    /// Close the preview panel explicitly (e.g. on Escape).
    func closePreview()
}

// MARK: - PreviewNavigationDirection

/// Direction for navigating results during preview.
enum PreviewNavigationDirection: Sendable {
    case up
    case down
}

// MARK: - QuickLookMetadataFallback

/// Metadata shown when Quick Look cannot preview a file type.
///
/// Displays the filename, size, and modification date as a readable summary.
struct QuickLookMetadataFallback: Sendable, Equatable {
    let filename: String
    let size: Int64
    let modifiedAt: Date
    let path: String
}

// MARK: - QuickLookPreviewableTypes

/// File extensions that QLPreviewPanel can typically render.
///
/// Shared between `QuickLookPreviewState` (for metadata fallback logic)
/// and `QuickLookPreviewController` (for `isPreviewable` static check).
/// Also accessible from tests for direct verification.
enum QuickLookPreviewableTypes: Sendable {

    static let extensions: Set<String> = [
        // Images
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "svg", "heic", "heif", "webp", "ico",
        // Documents
        "pdf", "rtf", "rtfd",
        // Text / code
        "txt", "md", "html", "htm", "xml", "json", "yaml", "yml", "csv", "tsv",
        "swift", "py", "js", "ts", "c", "cpp", "h", "hpp", "java", "rb", "go", "rs", "sh", "bash",
        "css", "scss", "less",
        // Audio
        "mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff",
        // Video
        "mp4", "mov", "m4v", "avi", "mkv", "wmv",
        // Office
        "pages", "numbers", "key", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
    ]

    /// Returns `true` if the given file extension is previewable by QLPreviewPanel.
    static func isPreviewable(_ ext: String?) -> Bool {
        guard let ext = ext?.lowercased() else { return false }
        return extensions.contains(ext)
    }
}

// MARK: - QuickLookPreviewState

/// Observable state for Quick Look preview, extracted for testability.
///
/// Tracks whether the preview is open, which result is being previewed,
/// and whether a metadata fallback should be displayed.
@MainActor @Observable
final class QuickLookPreviewState {

    /// Whether the preview panel is currently visible.
    private(set) var isPreviewOpen: Bool = false

    /// Index of the currently previewed result, or nil if preview is closed.
    private(set) var previewIndex: Int? = nil

    /// Metadata fallback for unsupported file types.
    private(set) var metadataFallback: QuickLookMetadataFallback? = nil

    /// Open the preview at the given index.
    func open(at index: Int, result: SearchResult) {
        isPreviewOpen = true
        previewIndex = index
        updateMetadataFallback(result: result)
    }

    /// Close the preview.
    func close() {
        isPreviewOpen = false
        previewIndex = nil
        metadataFallback = nil
    }

    /// Navigate to a new index and update the fallback.
    func navigate(to index: Int, result: SearchResult) {
        previewIndex = index
        updateMetadataFallback(result: result)
    }

    // MARK: - Private

    private func updateMetadataFallback(result: SearchResult) {
        let record = result.record
        if !QuickLookPreviewableTypes.isPreviewable(record.extension) {
            metadataFallback = QuickLookMetadataFallback(
                filename: record.originalName,
                size: record.size,
                modifiedAt: record.modifiedAt,
                path: record.path
            )
        } else {
            metadataFallback = nil
        }
    }
}

// MARK: - QuickLookPreviewController

/// Manages the QLPreviewPanel lifecycle for file previewing.
///
/// Integrates with the search results list: Space toggles the preview panel,
/// arrow keys navigate between results while the preview is open.
/// Unsupported file types produce a ``QuickLookMetadataFallback`` that the
/// UI can display instead of the native Quick Look preview.
///
/// Usage: wire `togglePreview` to Space key, `navigatePreview` to arrow keys,
/// and `closePreview` to Escape. The controller owns the QLPreviewPanel
/// data source.
@MainActor
final class QuickLookPreviewController: NSObject, QuickLookPreviewProtocol {

    // MARK: - State

    private let state = QuickLookPreviewState()

    /// Current results being browsed.
    private var results: [SearchResult] = []

    /// Whether the controller currently accepts panel control.
    private var acceptsPanel: Bool = false

    // MARK: - QuickLookPreviewProtocol Conformance

    var isPreviewOpen: Bool { state.isPreviewOpen }
    var previewIndex: Int? { state.previewIndex }
    var metadataFallback: QuickLookMetadataFallback? { state.metadataFallback }

    // MARK: - Toggle

    func togglePreview(results: [SearchResult], selectedIndex: Int?) {
        if state.isPreviewOpen {
            closePreview()
            return
        }

        guard let index = selectedIndex, index >= 0, index < results.count else {
            return
        }

        self.results = results
        acceptsPanel = true
        state.open(at: index, result: results[index])
        refreshPanel()
    }

    // MARK: - Navigation

    func navigatePreview(results: [SearchResult], direction: PreviewNavigationDirection) -> Int? {
        guard state.isPreviewOpen else { return nil }
        guard !results.isEmpty else { return nil }

        let current = state.previewIndex ?? 0
        let newIndex: Int

        switch direction {
        case .up:
            newIndex = (current - 1 + results.count) % results.count
        case .down:
            newIndex = (current + 1) % results.count
        }

        self.results = results
        state.navigate(to: newIndex, result: results[newIndex])
        refreshPanel()
        return newIndex
    }

    // MARK: - Close

    func closePreview() {
        state.close()
        acceptsPanel = false

        guard canUseQLPanel else { return }
        let panel = QLPreviewPanel.shared()
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Previewability Check

    /// Returns `true` if the file record has an extension that QLPreviewPanel can preview.
    /// Delegates to `QuickLookPreviewableTypes` for the actual extension check.
    nonisolated static func isPreviewable(_ record: FileRecord) -> Bool {
        QuickLookPreviewableTypes.isPreviewable(record.extension)
    }
}

// MARK: - QLPreviewPanelDataSource

extension QuickLookPreviewController: QLPreviewPanelDataSource {

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // QLPreviewPanel DataSource protocol requires nonisolated conformance (Objective-C).
        // QLPreviewPanel delegate callbacks are invoked on the main thread by AppKit,
        // so MainActor.assumeIsolated is safe here. If macOS ever calls this from a
        // background thread, assumeIsolated will crash — this is an intentional guard.
        guard let previewIndex = MainActor.assumeIsolated({
            self.state.previewIndex
        }) else {
            return nil
        }

        let results = MainActor.assumeIsolated({
            self.results
        })

        guard previewIndex >= 0, previewIndex < results.count else {
            return nil
        }

        let record = results[previewIndex].record
        return PreviewableItem(url: URL(fileURLWithPath: record.path), title: record.originalName)
    }
}

// MARK: - QLPreviewPanelDelegate

extension QuickLookPreviewController: QLPreviewPanelDelegate {

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Panel is under our control.
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Panel is no longer under our control.
    }
}

// MARK: - Panel Refresh

extension QuickLookPreviewController {

    /// Refresh the shared QLPreviewPanel to reflect the current preview index.
    private func refreshPanel() {
        // Guard: QLPreviewPanel crashes (SEGV in QLFadeWindowEffect) when used
        // outside a real AppKit window-server context (e.g. swift-testing runner).
        guard canUseQLPanel else { return }

        let panel = QLPreviewPanel.shared()
        guard let panel else { return }

        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        } else {
            panel.reloadData()
        }
    }

    /// Whether QLPreviewPanel can safely be used in the current process.
    ///
    /// Returns `false` in test runners and other headless contexts where
    /// `QLPreviewPanel.shared()` would create a panel that crashes on
    /// deallocation (SEGV in `QLFadeWindowEffect done`).
    private var canUseQLPanel: Bool {
        // NSApplication may not exist in test runners; checking screens
        // confirms a window server is available.
        NSApp != nil && !NSScreen.screens.isEmpty
    }
}

// MARK: - PreviewableItem

/// A simple QLPreviewItem wrapping a file URL and display title.
///
/// Used to bridge `SearchResult.record` to the QLPreviewPanel data source.
final class PreviewableItem: NSObject, QLPreviewItem {

    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}
