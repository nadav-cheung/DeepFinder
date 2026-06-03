import SwiftUI
import AppKit

// MARK: - ResultsListState

/// Observable state driving ResultsListView.
/// Extracted from the view for unit-testability without a host app.
/// All mutation methods are value-semantic on @Observable properties.
@Observable
final class ResultsListState {

    // MARK: - Constants

    static let pageSize = 100
    static let maxResults = Constants.GUI.maxResults

    /// Minimum number of rows the list should display.
    /// REQ-3.2-07: ensures at least 20 rows are visible.
    static let minVisibleRows = 20

    /// Fixed row height in points.
    /// REQ-3.2-14: constant height enables virtual scroll offset calculation.
    static let rowHeight: CGFloat = 40

    // MARK: - Stored properties

    /// All results kept after cap (max 10 000).
    private(set) var allResults: [SearchResult] = []

    /// How many results are currently visible (pagination).
    private(set) var visibleCount: Int = 0

    /// Currently selected row index (nil = no selection).
    private(set) var selectedIndex: Int? = nil

    /// Sets the selected index directly (e.g. from mouse click).
    func setSelectedIndex(_ index: Int?) {
        selectedIndex = index
    }

    /// Whether the original result set exceeded the cap.
    private(set) var wasCapped: Bool = false

    /// Current search query (for match highlighting in rows).
    var currentQuery: String = ""

    /// Total result count as reported by the input layer.
    /// May differ from `allResults.count` when results are capped.
    var totalResultCount: Int = 0

    // MARK: - Derived

    /// Results currently visible in the list.
    var visibleResults: [SearchResult] {
        let end = min(visibleCount, allResults.count)
        return Array(allResults[..<end])
    }

    /// Whether there are more results beyond the visible window.
    var hasMoreResults: Bool {
        visibleCount < allResults.count
    }

    /// Whether the result list is empty.
    var isEmpty: Bool {
        allResults.isEmpty
    }

    /// Whether results were capped at maxResults.
    var isCapped: Bool {
        wasCapped
    }

    /// Status text shown below the list.
    var statusText: String {
        if wasCapped {
            return "结果过多，请缩小搜索范围"
        }
        if allResults.isEmpty {
            return "未找到匹配文件"
        }
        let shown = min(visibleCount, allResults.count)
        return "\(shown) / \(allResults.count) 个结果"
    }

    /// Remaining count beyond visible window.
    var remainingCount: Int {
        allResults.count - visibleCount
    }

    /// Formatted total count with thousands separator.
    /// REQ-3.2-13: "1,234" format for the result count footer.
    var formattedResultCount: String {
        let count = totalResultCount > 0 ? totalResultCount : allResults.count
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    // MARK: - Mutation

    /// Set a new result set (new query). Resets pagination and selection.
    func setResults(_ results: [SearchResult]) {
        wasCapped = results.count > Self.maxResults
        allResults = Array(results.prefix(Self.maxResults))
        totalResultCount = results.count
        visibleCount = min(Self.pageSize, allResults.count)
        selectedIndex = nil
    }

    /// Show the next page of results.
    func loadMore() {
        guard hasMoreResults else { return }
        visibleCount = min(visibleCount + Self.pageSize, allResults.count)
    }

    /// Move the selection up or down, wrapping at boundaries.
    func moveSelection(down: Bool) {
        let count = min(visibleCount, allResults.count)
        guard count > 0 else { return }

        if selectedIndex == nil {
            selectedIndex = down ? 0 : count - 1
            return
        }

        guard let current = selectedIndex else { return }

        if down {
            selectedIndex = (current + 1) % count
        } else {
            selectedIndex = (current - 1 + count) % count
        }
    }

    /// Move selection by a full page (minVisibleRows rows).
    /// REQ-3.2-10: no wrap at boundaries — clamps to first/last row.
    func moveSelectionPage(down: Bool) {
        let count = min(visibleCount, allResults.count)
        guard count > 0 else { return }

        if selectedIndex == nil {
            selectedIndex = down ? 0 : count - 1
            return
        }

        guard let current = selectedIndex else { return }

        if down {
            selectedIndex = min(current + Self.minVisibleRows, count - 1)
        } else {
            selectedIndex = max(current - Self.minVisibleRows, 0)
        }
    }

    /// Move selection to the next/previous category group boundary.
    /// REQ-3.2-11: jumps between ResultCategory groups. When no categories
    /// are provided (empty array), jumps to first/last row instead.
    func moveSelectionToGroup(categories: [ResultCategory], down: Bool) {
        let count = min(visibleCount, allResults.count)
        guard count > 0 else { return }

        // Without categories, behave as Home/End.
        guard !categories.isEmpty else {
            selectedIndex = down ? count - 1 : 0
            return
        }

        if selectedIndex == nil {
            selectedIndex = down ? 0 : count - 1
            return
        }

        guard let current = selectedIndex else { return }
        let results = visibleResults
        let currentCategory = ResultCategory.categorize(results[current])

        if down {
            for i in (current + 1)..<count {
                if ResultCategory.categorize(results[i]) != currentCategory {
                    selectedIndex = i
                    return
                }
            }
            selectedIndex = count - 1
        } else {
            for i in stride(from: current - 1, through: 0, by: -1) {
                if ResultCategory.categorize(results[i]) != currentCategory {
                    let targetCategory = ResultCategory.categorize(results[i])
                    var lastInGroup = i
                    for j in stride(from: i, through: 0, by: -1) {
                        if ResultCategory.categorize(results[j]) == targetCategory {
                            lastInGroup = j
                        } else {
                            break
                        }
                    }
                    selectedIndex = lastInGroup
                    return
                }
            }
            selectedIndex = 0
        }
    }
}

// MARK: - ResultsListView

/// Displays search results in a virtualized list with keyboard navigation.
///
/// REQ-3.2-07: minimum 20 visible rows.
/// REQ-3.2-08: selection highlight with animation.
/// REQ-3.2-09: auto-scroll to selected row via ScrollViewReader.
/// REQ-3.2-10: Option+arrow page navigation.
/// REQ-3.2-11: Command+arrow group navigation.
/// REQ-3.2-13: fixed result count footer.
/// REQ-3.2-14: LazyVStack virtual scrolling.
/// REQ-3.2-17: selection highlight animation with fast-key merging.
/// REQ-3.2-18: fade-in transitions on results.
/// REQ-3.2-23: hover effect on rows.
/// REQ-3.2-24: Enter to open file.
/// REQ-3.2-25: Cmd+Enter to reveal in Finder.
/// REQ-3.2-26: Space / Cmd+Y Quick Look.
/// REQ-3.2-27: Cmd+C copy path with toast.
/// REQ-3.2-30: layered Escape handling.
/// REQ-3.2-31: Cmd+K action panel.
/// REQ-3.2-34: EmptyStateView for zero results.
/// REQ-3.2-36: stable results on rapid input.
struct ResultsListView: View {

    @Bindable var state: ResultsListState
    @FocusState private var isFocused: Bool
    private let quickLookController = QuickLookPreviewController()

    // MARK: - Callbacks

    /// Called when the user activates a file (Enter key).
    var onOpen: (SearchResult) -> Void = { _ in }

    /// Called when the user reveals a file in Finder (Cmd+Enter).
    var onReveal: (SearchResult) -> Void = { _ in }

    // MARK: - Panel State

    @State private var showDetailPanel: Bool = false
    @State private var showActionPanel: Bool = false
    @State private var toastMessage: String?

    // MARK: - Scroll State

    /// Tracks the last scroll animation timestamp to coalesce rapid key presses.
    /// REQ-3.2-09 / REQ-3.2-17: if < 0.1s apart, skip animation.
    @State private var lastScrollTime: Date = .distantPast

    /// Held reference to the ScrollViewReader proxy for programmatic scrolling.
    @State private var scrollProxy: ScrollViewProxy? = nil

    // MARK: - Hover State

    /// Index of the row currently under the mouse cursor, if any.
    @State private var hoveredIndex: Int? = nil

    // MARK: - Constants

    private static let scrollCoalescingInterval: TimeInterval = 0.1
    private static let scrollAnimationDuration: Double = 0.15
    private static let highlightAnimationDuration: Double = 0.12

    /// Minimum list height to accommodate minVisibleRows rows.
    /// REQ-3.2-07: 20 rows * 40pt = 800pt.
    private var minListHeight: CGFloat {
        CGFloat(ResultsListState.minVisibleRows) * ResultsListState.rowHeight
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            mainContent

            // Detail panel overlay (right side) — REQ-3.2-28
            if showDetailPanel, let selected = state.selectedIndex, selected < state.visibleResults.count {
                HStack {
                    Spacer()
                    FileDetailView(result: state.visibleResults[selected])
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Action panel overlay — REQ-3.2-31
            if showActionPanel, let selected = state.selectedIndex, selected < state.visibleResults.count {
                actionPanelOverlay
                    .transition(.opacity)
            }
        }
        .showToast($toastMessage)
        .animation(.easeInOut(duration: 0.2), value: showDetailPanel)
        .animation(.easeInOut(duration: 0.15), value: showActionPanel)
    }

    // MARK: - Main Content (list or empty state)

    private var mainContent: some View {
        Group {
            if state.isEmpty {
                emptyState
            } else {
                resultListWithFooter
            }
        }
        .focusable()
        .focused($isFocused)
        .onChange(of: state.selectedIndex) { _, newIndex in
            guard let newIndex else { return }
            scrollToRow(newIndex)
            syncQuickLookIfNeeded(newIndex)
        }
        // Basic keyboard handlers (no modifiers).
        .onKeyPress(.space) { handleSpace(); return .handled }
        .onKeyPress(.escape) { handleEscape() }
        // All modifier-aware keyboard handlers.
        .modifier(ExtendedKeyboardHandlers(view: self))
    }

    // MARK: - Empty State (REQ-3.2-34)

    private var emptyState: some View {
        EmptyStateView(query: state.currentQuery)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result List with Footer

    /// Combines the scrollable result list with a fixed result count footer.
    /// REQ-3.2-13: footer is fixed at bottom, not inside the scroll area.
    /// REQ-3.2-06: KeyboardHintBar shown at bottom when results are visible.
    private var resultListWithFooter: some View {
        VStack(spacing: 0) {
            resultScrollView
                .frame(minHeight: minListHeight, maxHeight: .infinity)

            resultCountFooter

            KeyboardHintBar()
        }
    }

    // MARK: - Scroll View (REQ-3.2-09, REQ-3.2-14, REQ-3.2-32)

    private var resultScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let groups = Self.categorizeResults(state.visibleResults)
                    ForEach(groups, id: \.startIndex) { group in
                        // REQ-3.2-32: category section header
                        categoryHeader(category: group.category, count: group.results.count, startIndex: group.startIndex)

                        // Result rows for this category
                        ForEach(
                            Array(group.results.enumerated()),
                            id: \.element.record.id
                        ) { localIndex, result in
                            let absoluteIndex = group.startIndex + localIndex
                            rowContent(index: absoluteIndex, result: result)
                        }
                    }

                    loadMoreFooter
                    capWarning
                }
            }
            .onAppear {
                scrollProxy = proxy
            }
        }
    }

    /// REQ-3.2-32: Groups results by category for section headers.
    /// Returns groups with absolute start indices so selection mapping stays correct.
    private static func categorizeResults(_ results: [SearchResult]) -> [(category: ResultCategory, startIndex: Int, results: [SearchResult])] {
        guard !results.isEmpty else { return [] }

        var groups: [(category: ResultCategory, startIndex: Int, results: [SearchResult])] = []
        var currentCategory = ResultCategory.categorize(results[0])
        var currentGroup: [SearchResult] = [results[0]]
        var groupStart = 0

        for i in 1..<results.count {
            let cat = ResultCategory.categorize(results[i])
            if cat == currentCategory {
                currentGroup.append(results[i])
            } else {
                groups.append((category: currentCategory, startIndex: groupStart, results: currentGroup))
                currentCategory = cat
                currentGroup = [results[i]]
                groupStart = i
            }
        }
        groups.append((category: currentCategory, startIndex: groupStart, results: currentGroup))
        return groups
    }

    /// REQ-3.2-32: Category section header row. Not selectable — skipped in keyboard navigation.
    private func categoryHeader(category: ResultCategory, count: Int, startIndex: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            Text(category.displayName)
                .font(.system(size: 11, weight: .semibold))

            Text("(\(count))")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3))
        .id("header_\(startIndex)")
        .allowsHitTesting(false)
    }

    // MARK: - Row Content (extracted to help type-checker)

    private func rowContent(index: Int, result: SearchResult) -> some View {
        ResultRowView(
            result: result,
            isSelected: index == state.selectedIndex,
            query: state.currentQuery
        )
        .id(index)
        .accessibilityIdentifier("result_row_\(index)")
        .background(rowBackground(for: index))
        .contentShape(Rectangle())
        .onTapGesture {
            selectAndOpen(index: index, result: result)
        }
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
        }
        // REQ-3.2-18: staggered fade-in for first 5 rows, plain opacity for rest.
        .transition(
            index < 5
                ? .opacity.combined(with: .move(edge: .top))
                : .opacity
        )
        .animation(
            index < 5
                ? .easeInOut(duration: 0.2).delay(Double(index) * 0.03)
                : .default,
            value: state.allResults.count
        )
    }

    /// Separated tap handler to give the type-checker a concrete return type.
    private func selectAndOpen(index: Int, result: SearchResult) {
        state.setSelectedIndex(index)
        onOpen(result)
    }

    // MARK: - Load More / Cap Warning

    private var loadMoreFooter: some View {
        Group {
            if state.hasMoreResults {
                Button {
                    state.loadMore()
                } label: {
                    Text("还有 \(state.remainingCount) 个结果")
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("load_more")
            }
        }
    }

    private var capWarning: some View {
        Group {
            if state.isCapped {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("cap_warning")
            }
        }
    }

    // MARK: - Row Background (REQ-3.2-08, REQ-3.2-23)

    @ViewBuilder
    private func rowBackground(for index: Int) -> some View {
        let isSelected = index == state.selectedIndex
        let isHovered = index == hoveredIndex

        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.2)
                    : isHovered
                        ? Color.secondary.opacity(0.1)
                        : Color.clear
            )
            .padding(.horizontal, 4)
            .animation(
                .easeInOut(duration: isSelected ? Self.highlightAnimationDuration : 0.15),
                value: isSelected
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Result Count Footer (REQ-3.2-13)

    private var resultCountFooter: some View {
        HStack {
            Spacer()
            Text("\(state.formattedResultCount) 个结果")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("result_count_footer")
    }

    // MARK: - Action Panel Overlay (REQ-3.2-31)

    private var actionPanelOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture {
                    showActionPanel = false
                }

            ActionPanelView { action in
                showActionPanel = false
                handleFileAction(action)
            }
            .frame(maxWidth: 320)
        }
    }

    // MARK: - Scroll Helpers (REQ-3.2-09)

    private func scrollToRow(_ index: Int) {
        let now = Date()
        let interval = now.timeIntervalSince(lastScrollTime)
        lastScrollTime = now

        guard let proxy = scrollProxy else { return }

        if interval < Self.scrollCoalescingInterval {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: Self.scrollAnimationDuration)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func syncQuickLookIfNeeded(_ newIndex: Int) {
        guard quickLookController.isPreviewOpen else { return }
        let results = state.visibleResults
        guard newIndex >= 0, newIndex < results.count else { return }

        let direction: PreviewNavigationDirection = (quickLookController.previewIndex ?? 0) < newIndex
            ? .down
            : .up
        _ = quickLookController.navigatePreview(results: results, direction: direction)
    }

    // MARK: - Keyboard Handlers

    /// Handles arrow-up with modifier awareness (plain = move, option = page, command = group).
    fileprivate func handleArrowUpWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            state.moveSelectionToGroup(categories: ResultCategory.allCases, down: false)
        } else if press.modifiers.contains(.option) {
            state.moveSelectionPage(down: false)
        } else {
            if quickLookController.isPreviewOpen {
                _ = quickLookController.navigatePreview(
                    results: state.visibleResults,
                    direction: .up
                )
            }
            state.moveSelection(down: false)
        }
        return .handled
    }

    /// Handles arrow-down with modifier awareness (plain = move, option = page, command = group).
    fileprivate func handleArrowDownWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            state.moveSelectionToGroup(categories: ResultCategory.allCases, down: true)
        } else if press.modifiers.contains(.option) {
            state.moveSelectionPage(down: true)
        } else {
            if quickLookController.isPreviewOpen {
                _ = quickLookController.navigatePreview(
                    results: state.visibleResults,
                    direction: .down
                )
            }
            state.moveSelection(down: true)
        }
        return .handled
    }

    /// Handles return with modifier awareness (plain = open, command = reveal).
    fileprivate func handleReturnWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            handleCommandReturn()
        } else {
            handleReturn()
        }
        return .handled
    }

    /// Handles Cmd+Y (Quick Look toggle).
    fileprivate func handleYWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        handleSpace()
        return .handled
    }

    /// Handles Cmd+C (copy path).
    fileprivate func handleCWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        handleCopyPath()
        return .handled
    }

    /// Handles Cmd+I (toggle detail panel).
    fileprivate func handleIWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        toggleDetailPanel()
        return .handled
    }

    /// Handles Cmd+K (toggle action panel).
    fileprivate func handleKWithModifiers(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }
        toggleActionPanel()
        return .handled
    }

    /// REQ-3.2-24: Enter opens the selected file.
    private func handleReturn() {
        guard let index = state.selectedIndex,
              index < state.visibleResults.count else { return }
        onOpen(state.visibleResults[index])
    }

    /// REQ-3.2-25: Cmd+Enter reveals in Finder.
    private func handleCommandReturn() {
        guard let index = state.selectedIndex,
              index < state.visibleResults.count else { return }
        onReveal(state.visibleResults[index])
    }

    /// REQ-3.2-26: Space / Cmd+Y toggles Quick Look.
    private func handleSpace() {
        quickLookController.togglePreview(
            results: state.visibleResults,
            selectedIndex: state.selectedIndex
        )
    }

    /// REQ-3.2-27: Cmd+C copies selected file path to clipboard.
    private func handleCopyPath() {
        guard let index = state.selectedIndex,
              index < state.visibleResults.count else { return }

        let path = state.visibleResults[index].record.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        toastMessage = "已复制路径"
    }

    /// REQ-3.2-30: Layered Escape handling.
    /// Priority: Quick Look > Action panel > Detail panel > ignored.
    private func handleEscape() -> KeyPress.Result {
        if quickLookController.isPreviewOpen {
            quickLookController.closePreview()
            return .handled
        }
        if showActionPanel {
            showActionPanel = false
            return .handled
        }
        if showDetailPanel {
            showDetailPanel = false
            return .handled
        }
        return .ignored
    }

    /// Toggles the detail panel (called from ViewModifier).
    fileprivate func toggleDetailPanel() {
        showDetailPanel.toggle()
    }

    /// Toggles the action panel (called from ViewModifier).
    fileprivate func toggleActionPanel() {
        showActionPanel.toggle()
    }

    // MARK: - File Action Dispatch (from ActionPanelView)

    private func handleFileAction(_ action: FileAction) {
        guard let index = state.selectedIndex,
              index < state.visibleResults.count else { return }
        let result = state.visibleResults[index]

        switch action {
        case .open:
            onOpen(result)
        case .reveal:
            onReveal(result)
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.record.path, forType: .string)
            toastMessage = "已复制路径"
        case .quickLook:
            quickLookController.togglePreview(
                results: state.visibleResults,
                selectedIndex: state.selectedIndex
            )
        case .getInfo:
            showDetailPanel = true
        case .trash:
            let url = URL(fileURLWithPath: result.record.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                toastMessage = "无法移到废纸篓: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Extended Keyboard Handlers (ViewModifier)

/// A ViewModifier that uses the `onKeyPress(phases:action:)` overload
/// (which receives a `KeyPress` struct with modifier information) to handle
/// modifier-key combinations. Applied separately from the main body to keep
/// the type-checker within expression complexity limits.
private struct ExtendedKeyboardHandlers: ViewModifier {
    fileprivate let view: ResultsListView

    func body(content: Content) -> some View {
        content
            // Arrow keys — check modifiers on the KeyPress event.
            .onKeyPress(.upArrow, phases: .down) { press in
                view.handleArrowUpWithModifiers(press)
            }
            .onKeyPress(.downArrow, phases: .down) { press in
                view.handleArrowDownWithModifiers(press)
            }
            .onKeyPress(.return, phases: .down) { press in
                view.handleReturnWithModifiers(press)
            }
            .onKeyPress("y", phases: .down) { press in
                view.handleYWithModifiers(press)
            }
            .onKeyPress("c", phases: .down) { press in
                view.handleCWithModifiers(press)
            }
            .onKeyPress("i", phases: .down) { press in
                view.handleIWithModifiers(press)
            }
            .onKeyPress("k", phases: .down) { press in
                view.handleKWithModifiers(press)
            }
            // REQ-3.2-08: Ctrl+N / Ctrl+P Emacs aliases for ↓ / ↑
            .onKeyPress("n", phases: .down) { press in
                guard press.modifiers.contains(.control) else { return .ignored }
                view.state.moveSelection(down: true)
                return .handled
            }
            .onKeyPress("p", phases: .down) { press in
                guard press.modifiers.contains(.control) else { return .ignored }
                view.state.moveSelection(down: false)
                return .handled
            }
    }
}
