import SwiftUI
import AppKit
import Speech
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

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
public struct SearchPanelView: View {

    @ObservedObject var viewModel: SearchViewModel
    @State private var resultsListState = ResultsListState()

    // MARK: - REQ-3.2-01: Dynamic Placeholder

    /// Candidate placeholder strings, rotated on each panel open.
    public static let placeholders = [
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

    /// Whether a newer version is available (bound from viewModel).
    /// Kept as @State for the view's animation value, synced from viewModel.updateAvailable.
    @State private var updateAvailable: Bool = false

    /// Tracks which history row is currently hovered (for subtle highlight).
    @State private var hoveredHistoryIndex: Int?

    /// View model for the speech overlay, lazily created on first use.
    @State private var speechViewModel: SpeechOverlayViewModel? = nil

    /// Drives the scale-in animation for error state icons.
    @State private var errorIconAppeared: Bool = false

    // MARK: - REQ-3.2-20: Focus State

    /// Tracks whether the search text field has keyboard focus.
    @FocusState private var isSearchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Syntax Error Detection

    /// Delegates syntax error detection to the view model.
    private var syntaxError: String? { viewModel.syntaxError }

    // MARK: - Body

    public var body: some View {
        GlassEffectContainer(
            intensity: .regular,
            cornerRadius: 24,
            glowActive: isSearchFocused,
            showTexture: true,
            innerShadow: true
        ) {
            VStack(spacing: 0) {
                searchBarArea
                // syntaxError animation value
                Rectangle()
                    .fill(.separator.opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.horizontal, 8)
                // Syntax error hint banner (non-blocking)
                if let error = syntaxError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GlowColors.amber)
                            .font(.system(size: 12))
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(GlowColors.coral.opacity(0.10))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("语法错误: \(error)")
                }
                // REQ-3.2-35: category filter bar
                SearchFilterBar(activeFilters: $activeFilters)
                Rectangle()
                    .fill(.separator.opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.horizontal, 8)
                // Index health banner (degraded state)
                if let monitor = viewModel.indexHealthMonitor,
                   case .degraded = monitor.healthState {
                    IndexHealthBanner(
                        healthState: monitor.healthState,
                        onOpenSettings: { NotificationCenter.default.post(name: .showSettings, object: nil) }
                    )
                }

                // Index building progress (indexing state)
                if let monitor = viewModel.indexHealthMonitor,
                   case .indexing(let filesIndexed) = monitor.healthState {
                    IndexBuildingProgressView(filesIndexed: filesIndexed)
                }
                contentArea
            }
            .frame(minWidth: 480, maxWidth: 800)
            .animation(.easeInOut(duration: 0.2), value: syntaxError)
        }
        .showToast($viewModel.toastMessage)
        .overlay {
            // REQ-3.2-03: speech overlay centered over the panel
            if showSpeech, let speechViewModel {
                ZStack {
                    Color.black.opacity(0.2)
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
        .onChange(of: viewModel.updateAvailable) { _, newValue in
            updateAvailable = newValue
        }
        .onChange(of: viewModel.searchText) { _, newQuery in
            resultsListState.currentQuery = newQuery
            viewModel.showHistoryDropdown = false
        }
        .onChange(of: resultsListState.selectedIndex) { _, newIndex in
            viewModel.selectedIndex = newIndex
        }
        // REQ-3.2-35: when active filters change, append filter syntax to search text.
        .onChange(of: activeFilters) { _, newFilters in
            let combined = Self.buildFilterQuery(base: viewModel.searchText, filters: newFilters)
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
            // REQ-3.2-02: ↑ in empty search toggles history dropdown
            .onKeyPress(.upArrow) {
                guard viewModel.searchText.isEmpty else { return .ignored }
                viewModel.toggleHistoryDropdown()
                return .handled
            }
            // REQ-3.2-29: Tab autocomplete from selected result; Shift+Tab for parent directory.
            .onKeyPress(.tab, phases: .down) { press in
                guard let idx = resultsListState.selectedIndex,
                      idx < viewModel.results.count else { return .ignored }
                if press.modifiers.contains(.shift) {
                    let path = viewModel.results[idx].record.parentPath
                    viewModel.searchText = path + "/"
                } else {
                    viewModel.searchText = viewModel.results[idx].record.path
                }
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

            // Update available badge — only when search is empty
            if viewModel.searchText.isEmpty && updateAvailable {
                Button {
                    if let url = URL(string: "https://github.com/nadav-cheung/DeepFinder/releases") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("新版本")
                        .font(.system(size: 11))
                        .foregroundStyle(GlowColors.amber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(GlowColors.amber.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityLabel("新版本可用，点击查看")
            }

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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.searchText.isEmpty)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.showSpinner)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.searchTimedOut)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: updateAvailable)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // REQ-3.2-20: focus glow border on search bar.
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .opacity(isSearchFocused ? 0.5 : 0)
                .animation(.spring(duration: 0.3, bounce: 0.15), value: isSearchFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .allowsHitTesting(false)
        )
        .overlay(
            // REQ-3.2-20: subtle outer glow when focused.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 4)
                .opacity(isSearchFocused ? 1 : 0)
                .animation(.spring(duration: 0.3, bounce: 0.15), value: isSearchFocused)
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
            toggleSpeechOverlay()
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
                _ = viewModel.revealSelected()
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

            // Feature discovery tip (rotates on each panel open)
            let undismissedTips = FeatureTip.undismissed
            if !undismissedTips.isEmpty {
                let tip = undismissedTips[placeholderIndex % undismissedTips.count]
                FeatureDiscoveryTipCard(tip: tip) {
                    // Force re-read of undismissed tips
                    viewModel.searchText = viewModel.searchText
                }
            }

            Rectangle()
                .fill(.separator.opacity(0.3))
                .frame(height: 0.5)
                .padding(.horizontal, 8)

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
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 24))
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
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(hoveredHistoryIndex == index ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered in
            hoveredHistoryIndex = isHovered ? index : nil
        }
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
        EmptyStateView(
            query: viewModel.searchText,
            hasAIEnabled: true,
            fdaGranted: viewModel.fdaGranted,
            onOpenSettings: { NotificationCenter.default.post(name: .showSettings, object: nil) }
        )
    }

    private var daemonDisconnectedView: some View {
        ErrorStateCard(
            icon: "exclamationmark.triangle.fill",
            iconColor: GlowColors.amber,
            title: "搜索服务未连接",
            subtitle: "搜索服务未运行，请从菜单栏启动或等待自动启动。",
            iconAppeared: errorIconAppeared,
            retryAction: { Task { await viewModel.search() } }
        )
        .onAppear { errorIconAppeared = true }
    }

    private func searchErrorView(message: String) -> some View {
        ErrorStateCard(
            icon: "xmark.circle.fill",
            iconColor: GlowColors.coral,
            title: "搜索出错",
            subtitle: message,
            iconAppeared: errorIconAppeared,
            retryAction: { Task { await viewModel.search() } }
        )
        .onAppear { errorIconAppeared = true }
    }

    // MARK: - Actions

    /// Builds a combined query string from base text and active filters.
    /// REQ-3.2-35: extracted to help the Swift type-checker.
    private static func buildFilterQuery(base: String, filters: Set<FilterType>) -> String {
        let baseQuery = base.components(separatedBy: .whitespaces)
            .filter { !$0.hasPrefix("ext:") && !$0.hasPrefix("type:") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let filterParts = filters.sorted(by: { $0.rawValue < $1.rawValue })
            .map { $0.filterSyntax() }

        return ([baseQuery] + filterParts)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

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

// MARK: - ErrorStateCard

/// Shared card view for error/warning states in the search panel.
///
/// Used by both `daemonDisconnectedView` and `searchErrorView` to avoid
/// duplicating the layout, animation, and retry button structure.
private struct ErrorStateCard: View {
    public let icon: String
    public let iconColor: Color
    public let title: String
    public let subtitle: String
    public let iconAppeared: Bool
    public let retryAction: (() -> Void)?

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(iconColor)
                .background(
                    Circle()
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 48, height: 48)
                )
                .scaleEffect(iconAppeared ? 1 : 0.8)
                .animation(.spring(duration: 0.4, bounce: 0.2), value: iconAppeared)

            VStack(spacing: 4) {
                Text(title)
                    .font(DeepFinderTypography.subheading(size: 14))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let retryAction {
                Button("重试", action: retryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - SpeechOverlayActionsHandler

/// Bridges `SpeechOverlayActions` protocol to `SearchViewModel`.
/// REQ-3.2-03: on final speech result, fills search text and triggers search.
private final class SpeechOverlayActionsHandler: SpeechOverlayActions, @unchecked Sendable {
    private let viewModel: SearchViewModel

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    public func triggerSearch(_ query: String) async {
        await MainActor.run {
            viewModel.searchText = query
            Task { await viewModel.search() }
        }
    }

    public func dismissOverlay() {
        // No-op: the overlay dismiss is handled by the view's state.
    }
}
