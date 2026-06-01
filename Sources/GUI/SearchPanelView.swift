/// # GUI Module
///
/// The SwiftUI-based graphical interface for DeepFinder, implementing a
/// Spotlight-style floating search panel with Liquid Glass material effects.
///
/// ## Components
/// - ``SearchPanelView`` -- main search panel with search bar and results list
/// - ``SearchPanelHostingController`` -- NSPanel controller managing the floating window
/// - ``SearchBarView`` -- search input field with autocomplete support
/// - ``ResultsListView`` -- scrollable results container with keyboard navigation
/// - ``ResultRowView`` -- single result row displaying file name, path, size, and date
/// - ``SearchViewModel`` -- observable view model bridging GUI to IPC client
/// - ``IntelligenceGlow`` -- Apple Intelligence-inspired animated glow border
/// - ``GlassEffectContainer`` -- Liquid Glass material effect wrapper
/// - ``GlobalHotkey`` -- system-wide keyboard shortcut (Ctrl+Cmd+K) via RegisterEventHotKey
/// - ``HotkeyPermissionHelper`` -- Accessibility permission prompt for global hotkey
/// - ``SettingsView`` / ``SettingsWindow`` -- preferences panel for daemon configuration
/// - ``WorkspaceProtocol`` -- NSWorkspace protocol abstraction for testability
///
/// ## Architecture
/// The GUI connects to the same background daemon via IPC -- no search logic
/// runs in the GUI process. The ``SearchViewModel`` sends queries through an
/// ``IPCClientProtocol`` and receives ``SearchResult`` arrays.
///
/// ## Panel Behavior
/// - Floating NSPanel at `.floating` window level
/// - Centers on the screen containing the mouse cursor
/// - Dismisses on click-outside or Escape
/// - Reopening preserves search text and cursor position
/// - No Dock icon (LSUIElement menu bar app)
import SwiftUI
import AppKit

// MARK: - SearchPanelView

/// The main search panel view — a Spotlight-style floating window.
///
/// Hosted in an NSPanel via `SearchPanelHostingController`. Uses Liquid Glass
/// material effect, floating panel level, no title bar. Centers on the active
/// (mouse-location) screen. Dismisses on click-outside or Esc.
///
/// Reopening preserves search text and cursor position.
struct SearchPanelView: View {

    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                TextField("搜索文件...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .onSubmit {
                        Task { await viewModel.search() }
                    }

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.results = []
                        viewModel.hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Results area
            if viewModel.isLoading {
                ProgressView()
                    .padding(20)
                    .frame(maxWidth: .infinity)
            } else if viewModel.hasSearched && viewModel.results.isEmpty {
                errorStateView
            } else if !viewModel.results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.element.record.id) { index, result in
                            ResultRow(result: result, isSelected: viewModel.selectedIndex == index)
                                .onTapGesture {
                                    viewModel.selectedIndex = index
                                }
                                .onTapGesture(count: 2) {
                                    viewModel.selectedIndex = index
                                    _ = viewModel.openSelected()
                                }
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(minWidth: 480, maxWidth: 800)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: - Error State View

    /// Displays an appropriate error message based on the current `errorState`.
    ///
    /// - `.noResults`: simple "no matching files" message.
    /// - `.daemonDisconnected`: warning with a Retry button that re-runs the search.
    /// - `.searchError`: error message from the daemon with a Retry button.
    @ViewBuilder
    private var errorStateView: some View {
        if let errorState = viewModel.errorState {
            switch errorState {
            case .noResults:
                noResultsView
            case .daemonDisconnected:
                daemonDisconnectedView
            case .searchError(let message):
                searchErrorView(message: message)
            }
        } else {
            // Fallback: empty results without a typed error state
            noResultsView
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("未找到匹配文件")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var daemonDisconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)

            VStack(spacing: 4) {
                Text("Daemon not connected")
                    .font(.system(size: 14, weight: .semibold))
                Text("The search daemon is not running. Start it from the menu bar or wait for it to auto-start.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Retry") {
                Task { await viewModel.search() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private func searchErrorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)

            VStack(spacing: 4) {
                Text("Search Error")
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Retry") {
                Task { await viewModel.search() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ResultRow

/// A single row in the search results list.
private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // File icon
            Image(systemName: result.record.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.record.originalName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(shortenedPath(result.record.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatSize(result.record.size))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(formatDate(result.record.modifiedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - SearchPanelHostingController

/// NSPanel controller that hosts `SearchPanelView`.
///
/// Creates a floating, titleless NSPanel with Liquid Glass material.
/// Centers on the active screen (determined by mouse location).
/// Dismisses on click-outside or Esc key.
///
/// Reopening preserves the search text via the shared `SearchViewModel`.
@MainActor
final class SearchPanelHostingController {

    private var panel: NSPanel?
    private let viewModel: SearchViewModel

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Panel Lifecycle

    /// Show the search panel, centering on the screen where the mouse is located.
    func show() {
        if let existingPanel = panel, existingPanel.isVisible {
            existingPanel.makeKeyAndOrderFront(nil)
            existingPanel.makeFirstResponder(existingPanel.contentView)
            return
        }

        let targetScreen = screenForMouseLocation()
        let panelWidth = clampedPanelWidth(for: targetScreen)
        let panelSize = NSSize(width: panelWidth, height: 420)

        let newPanel = NSPanel(
            contentRect: NSRect(
                origin: centerOnScreen(targetScreen, size: panelSize),
                size: panelSize
            ),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        newPanel.level = .floating
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = false
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false

        // Click-through dismissal
        newPanel.hidesOnDeactivate = true

        // Host SwiftUI view
        let hostingView = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        hostingView.frame = newPanel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView?.addSubview(hostingView)

        self.panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        newPanel.makeFirstResponder(hostingView)
    }

    /// Hide the panel without destroying it (preserves search text).
    func hide() {
        panel?.orderOut(nil)
    }

    /// Toggle panel visibility.
    func toggle() {
        if let p = panel, p.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Screen Positioning

    /// Find the screen containing the mouse cursor, falling back to main or first screen.
    private func screenForMouseLocation() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }

        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Clamp panel width: min 480, max 800, no wider than screen minus margins.
    private func clampedPanelWidth(for screen: NSScreen) -> CGFloat {
        let margin: CGFloat = 80
        let maxFromScreen = screen.visibleFrame.width - margin * 2
        return min(max(480, maxFromScreen), 800)
    }

    /// Compute origin to center the panel near the top of the given screen.
    private func centerOnScreen(_ screen: NSScreen, size: NSSize) -> NSPoint {
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let topPadding: CGFloat = screenFrame.height * 0.15
        let y = screenFrame.maxY - topPadding - size.height
        return NSPoint(x: x, y: y)
    }
}
