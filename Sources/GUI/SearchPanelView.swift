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
import Speech

// MARK: - SearchPanel

/// A floating NSPanel that can become the key window so its text field
/// accepts keyboard input. Required because `.nonactivatingPanel` alone
/// prevents the window from becoming key, which blocks all text entry.
///
/// Only `canBecomeKey` is overridden — `canBecomeMain` stays `false` so
/// the panel doesn't appear in the Cmd+` window cycle.
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SearchPanelView

/// The main search panel view — a Spotlight-style floating window.
///
/// Hosted in an NSPanel via `SearchPanelHostingController`. Uses Liquid Glass
/// material effect via ``GlassEffectContainer``, floating panel level, no title bar.
/// Centers on the active (mouse-location) screen. Dismisses on click-outside or Esc.
///
/// Reopening preserves search text and cursor position.
///
/// REQ coverage:
/// - REQ-3.2-01: Dynamic placeholder cycling on each panel open.
/// - REQ-3.2-02: Search history dropdown when search bar is empty.
/// - REQ-3.2-03: Voice input via mic button + SpeechOverlayView.
/// - REQ-3.2-04: Loading spinner in search bar.
/// - REQ-3.2-05: Animated clear button + Esc clears text first.
/// - REQ-3.2-06: KeyboardHintBar shown in empty state.
/// - REQ-3.2-19: Panel open/close spring animation (in hosting controller).
/// - REQ-3.2-20: Focus glow on search bar border.
/// - REQ-3.2-29: Tab autocomplete from selected result.
struct SearchPanelView: View {

    @ObservedObject var viewModel: SearchViewModel
    @State private var resultsListState = ResultsListState()

    // MARK: - REQ-3.2-01: Dynamic Placeholder

    /// Candidate placeholder strings, rotated on each panel open.
    static let placeholders = [
        "搜索文件、文件夹...",
        "今天想找什么？",
        "输入关键词开始搜索...",
        "查找任意文件...",
        "搜索全磁盘文件..."
    ]

    /// Index into `placeholders`, advanced on each appear.
    @State private var placeholderIndex: Int = 0

    // MARK: - REQ-3.2-35: Filter Bar

    /// Currently active category filters, toggled by SearchFilterBar pills.
    @State private var activeFilters: Set<FilterType> = []

    // MARK: - REQ-3.2-03: Voice Input

    /// Whether the speech overlay is visible.
    @State private var showSpeech: Bool = false

    /// View model for the speech overlay, lazily created on first use.
    @State private var speechViewModel: SpeechOverlayViewModel? = nil

    // MARK: - REQ-3.2-20: Focus State

    /// Tracks whether the search text field has keyboard focus.
    @FocusState private var isSearchFocused: Bool

    // MARK: - Body

    var body: some View {
        GlassEffectContainer(
            intensity: .regular,
            cornerRadius: 24,
            glowActive: isSearchFocused
        ) {
            VStack(spacing: 0) {
                searchBarArea
                Divider()
                // REQ-3.2-35: category filter bar
                SearchFilterBar(activeFilters: $activeFilters)
                Divider()
                contentArea
            }
            .frame(minWidth: 480, maxWidth: 800)
        }
        .showToast($viewModel.toastMessage)
        .overlay {
            // REQ-3.2-03: speech overlay centered over the panel
            if showSpeech, let speechViewModel {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            speechViewModel.cancel()
                            showSpeech = false
                        }

                    SpeechOverlayView(viewModel: speechViewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                .animation(.easeInOut(duration: 0.2), value: showSpeech)
            }
        }
        .onAppear {
            // REQ-3.2-01: random placeholder on each panel open.
            placeholderIndex = Int.random(in: 0..<Self.placeholders.count)
            isSearchFocused = true
        }
        .onChange(of: viewModel.results) { _, newResults in
            resultsListState.setResults(newResults)
        }
        .onChange(of: viewModel.searchText) { _, newQuery in
            resultsListState.currentQuery = newQuery
        }
        .onChange(of: resultsListState.selectedIndex) { _, newIndex in
            viewModel.selectedIndex = newIndex
        }
        // REQ-3.2-35: when active filters change, append filter syntax to search text.
        .onChange(of: activeFilters) { _, newFilters in
            let baseQuery = viewModel.searchText.components(separatedBy: .whitespaces)
                .filter { !$0.hasPrefix("ext:") && !$0.hasPrefix("type:") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            let filterParts = newFilters.sorted(by: { $0.rawValue < $1.rawValue })
                .map { $0.filterSyntax() }

            let combined = ([baseQuery] + filterParts)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            viewModel.searchText = combined
        }
        // REQ-3.2-05: Esc clears text first; only dismisses panel when text is already empty.
        .onKeyPress(.escape) {
            if !viewModel.searchText.isEmpty {
                viewModel.searchText = ""
                isSearchFocused = true
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Search Bar (REQ-3.2-01/03/04/05/20)

    /// Inline search bar with magnifying glass icon, text field, loading spinner,
    /// mic button, and clear button.
    ///
    /// Built directly into SearchPanelView rather than using SearchBarView,
    /// because the panel's search bar has different layout requirements
    /// (no standalone container, tighter integration with the glass panel).
    private var searchBarArea: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            TextField(
                Self.placeholders[placeholderIndex % Self.placeholders.count],
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused($isSearchFocused)
            .onSubmit {
                Task { await viewModel.search() }
            }
            // REQ-3.2-29: Tab autocomplete from selected result.
            .onKeyPress(.tab) {
                guard let idx = resultsListState.selectedIndex,
                      idx < viewModel.results.count else { return .ignored }
                viewModel.searchText = viewModel.results[idx].record.path
                return .handled
            }
            // REQ-3.2-29: Shift+Tab autocomplete parent directory.
            .onKeyPress(.tab, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                guard let idx = resultsListState.selectedIndex,
                      idx < viewModel.results.count else { return .ignored }
                let path = viewModel.results[idx].record.parentPath
                viewModel.searchText = path + "/"
                return .handled
            }

            // REQ-3.2-04: loading spinner (between text field and action buttons).
            // Spinner only shows after 50ms threshold; timeout shows warning icon.
            if viewModel.showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else if viewModel.searchTimedOut {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14))
                    .frame(width: 16, height: 16)
            }

            // REQ-3.2-03: mic button for voice input.
            micButton

            // REQ-3.2-05: clear button with opacity transition.
            if !viewModel.searchText.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.searchText.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showSpinner)
        .animation(.easeInOut(duration: 0.2), value: viewModel.searchTimedOut)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // REQ-3.2-20: focus glow border on search bar.
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .opacity(isSearchFocused ? 0.5 : 0)
                .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .allowsHitTesting(false)
        )
        .overlay(
            // REQ-3.2-20: subtle outer glow when focused.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 4)
                .opacity(isSearchFocused ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Mic Button (REQ-3.2-03)

    /// Microphone button that toggles the speech overlay for voice input.
    /// REQ-3.2-03: shows dimmed mic with tooltip when permission not granted.
    @ViewBuilder
    private var micButton: some View {
        let micAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        Button {
            if micAuthorized {
                toggleSpeechOverlay()
            } else {
                toggleSpeechOverlay()
            }
        } label: {
            Image(systemName: showSpeech ? "mic.fill" : "mic")
                .foregroundStyle(
                    showSpeech ? Color.accentColor
                        : micAuthorized ? Color.secondary
                        : Color.secondary.opacity(0.5)
                )
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("语音输入")
        .help(micAuthorized ? "语音输入" : "需要在系统设置中授予麦克风权限")
    }

    // MARK: - Content Area

    /// Main content area below the search bar. Shows search history when idle,
    /// results when searching, loading/error states otherwise.
    @ViewBuilder
    private var contentArea: some View {
        if viewModel.isLoading && viewModel.results.isEmpty {
            // Loading state with no prior results
            ProgressView()
                .padding(20)
                .frame(maxWidth: .infinity)
        } else if viewModel.hasSearched && viewModel.results.isEmpty {
            // Error / no results state
            errorStateView
        } else if !viewModel.results.isEmpty {
            // Active results — REQ-3.2-24/25: wire open/reveal to viewModel
            ResultsListView(state: resultsListState) { result in
                if viewModel.openSelected() {
                    // Successfully opened — close panel
                    NSApp.keyWindow?.orderOut(nil)
                }
            } onReveal: { _ in
                viewModel.revealSelected()
            }
            .frame(maxHeight: .infinity)
        } else {
            // REQ-3.2-02 / REQ-3.2-06: idle state — history + keyboard hints
            idleStateView
        }
    }

    // MARK: - Idle State (REQ-3.2-02, REQ-3.2-06)

    /// Shows search history and keyboard hint bar when no search is active.
    private var idleStateView: some View {
        VStack(spacing: 0) {
            // REQ-3.2-06: keyboard hints at top.
            KeyboardHintBar()

            Divider()
                .padding(.horizontal, 12)

            // REQ-3.2-02: search history list.
            let entries = viewModel.searchHistory.recentEntries(limit: 10)
            if entries.isEmpty {
                emptyHistoryPlaceholder
            } else {
                historyList(entries: entries)
            }
        }
    }

    /// Placeholder when search history is empty.
    private var emptyHistoryPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("暂无搜索历史")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Scrollable list of search history entries.
    private func historyList(entries: [SearchHistoryEntry]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    historyRow(entry: entry, index: index)
                }

                // REQ-3.2-02: clear all history button
                if !entries.isEmpty {
                    Button {
                        viewModel.searchHistory.clearAll()
                    } label: {
                        Text("清除全部搜索历史")
                            .font(.system(size: 12))
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 380)
    }

    /// A single row in the search history list.
    private func historyRow(entry: SearchHistoryEntry, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
                .frame(width: 16)

            Text(entry.query)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Text(entry.timestamp, style: .relative)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            // Delete button
            Button {
                viewModel.searchHistory.removeEntry(at: index)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除历史记录")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.searchFromHistory(entry.query)
        }
    }

    // MARK: - Error State Views

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
            noResultsView
        }
    }

    private var noResultsView: some View {
        EmptyStateView(query: viewModel.searchText, hasAIEnabled: true)
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

    // MARK: - Actions

    /// Clears the search text, results, and selection state.
    /// REQ-3.2-05: search bar retains focus after clear.
    private func clearSearch() {
        viewModel.searchText = ""
        viewModel.results = []
        viewModel.hasSearched = false
        resultsListState.setResults([])
        isSearchFocused = true
    }

    // MARK: - Voice Input (REQ-3.2-03)

    /// Toggles the speech overlay on/off, creating the view model lazily.
    private func toggleSpeechOverlay() {
        if showSpeech {
            speechViewModel?.cancel()
            showSpeech = false
            return
        }

        let provider = LocalSpeechProvider()
        let actions = SpeechOverlayActionsHandler(viewModel: viewModel)
        let vm = SpeechOverlayViewModel(speechProvider: provider, actions: actions)
        speechViewModel = vm
        showSpeech = true
        vm.startListening()
    }
}

// MARK: - SpeechOverlayActionsHandler

/// Bridges `SpeechOverlayActions` protocol to `SearchViewModel`.
/// REQ-3.2-03: on final speech result, fills search text and triggers search.
private final class SpeechOverlayActionsHandler: SpeechOverlayActions, @unchecked Sendable {
    private let viewModel: SearchViewModel

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    func triggerSearch(_ query: String) async {
        await MainActor.run {
            viewModel.searchText = query
            Task { await viewModel.search() }
        }
    }

    func dismissOverlay() {
        // No-op: the overlay dismiss is handled by the view's state.
    }
}

// MARK: - SearchPanelHostingController

/// NSPanel controller that hosts `SearchPanelView`.
///
/// Creates a floating, titleless NSPanel with Liquid Glass material.
/// Centers on the active screen (determined by mouse location).
/// Dismisses on click-outside or Esc key.
///
/// REQ-3.2-07: panel height accommodates at least 20 result rows.
/// REQ-3.2-19: animated open/close with spring-like feel.
///
/// Reopening preserves the search text via the shared `SearchViewModel`.
@MainActor
public final class SearchPanelHostingController {

    private var panel: NSPanel?
    private let viewModel: SearchViewModel

    /// Fixed search bar height (padding + text field).
    private static let searchBarHeight: CGFloat = 48

    /// Height for 20 result rows (REQ-3.2-07).
    private static let minResultsHeight: CGFloat = CGFloat(ResultsListState.minVisibleRows) * ResultsListState.rowHeight

    /// Top padding from screen edge.
    private static let topPaddingRatio: CGFloat = 0.15

    /// Bottom margin.
    private static let bottomMargin: CGFloat = 20

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Panel Lifecycle

    /// Show the search panel, centering on the screen where the mouse is located.
    ///
    /// REQ-3.2-19: panel animates from search-bar-only height to full height.
    func show() {
        if let existingPanel = panel, existingPanel.isVisible {
            existingPanel.makeKeyAndOrderFront(nil)
            existingPanel.makeFirstResponder(existingPanel.contentView)
            return
        }

        let targetScreen = screenForMouseLocation()
        let panelWidth = clampedPanelWidth(for: targetScreen)

        // REQ-3.2-19: start at search-bar-only height, animate to full height.
        let startHeight = Self.searchBarHeight
        let targetHeight = clampedPanelHeight(for: targetScreen)

        let startSize = NSSize(width: panelWidth, height: startHeight)
        let targetSize = NSSize(width: panelWidth, height: targetHeight)
        let origin = centerOnScreen(targetScreen, size: targetSize)

        let newPanel = SearchPanel(
            contentRect: NSRect(origin: origin, size: startSize),
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

        // Dismiss when the user clicks outside (another app gains active status).
        // Safe now that `NSApplicationSupportsAutomaticTermination = NO` is set in
        // Info.plist — AppKit will not auto-terminate the app when the panel hides.
        newPanel.hidesOnDeactivate = true

        // Host SwiftUI view — set as contentView directly so first-responder
        // chaining works correctly for the TextField.
        let hostingView = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        hostingView.frame = newPanel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView

        self.panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        newPanel.makeFirstResponder(hostingView)

        // REQ-3.2-19: animate from search-bar-only to full height.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            context.allowsImplicitAnimation = true
            newPanel.animator().setFrame(
                NSRect(origin: origin, size: targetSize),
                display: true
            )
        }
    }

    /// Hide the panel without destroying it (preserves search text).
    /// REQ-3.2-19: animated collapse to search-bar height before ordering out.
    func hide() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let collapsedFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height - Self.searchBarHeight,
            width: currentFrame.width,
            height: Self.searchBarHeight
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.completionHandler = { panel.orderOut(nil) }
            panel.animator().setFrame(collapsedFrame, display: true)
        }
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

    /// Compute target panel height: search bar + results area, clamped to screen bounds.
    /// REQ-3.2-07: at least 20 rows visible, but not exceeding screen space.
    private func clampedPanelHeight(for screen: NSScreen) -> CGFloat {
        let screenFrame = screen.visibleFrame
        let topPadding = screenFrame.height * Self.topPaddingRatio
        let maxAvailable = screenFrame.height - topPadding - Self.bottomMargin

        let idealHeight = Self.searchBarHeight + Self.minResultsHeight

        return min(idealHeight, maxAvailable)
    }

    /// Compute origin to center the panel near the top of the given screen.
    private func centerOnScreen(_ screen: NSScreen, size: NSSize) -> NSPoint {
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let topPadding: CGFloat = screenFrame.height * Self.topPaddingRatio
        let y = screenFrame.maxY - topPadding - size.height
        return NSPoint(x: x, y: y)
    }
}
