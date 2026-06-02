import SwiftUI

// MARK: - ResultsListState

/// Observable state driving ResultsListView.
/// Extracted from the view for unit-testability without a host app.
/// All mutation methods are value-semantic on @Observable properties.
@Observable
final class ResultsListState {

    // MARK: - Constants

    static let pageSize = 100
    static let maxResults = Constants.GUI.maxResults

    // MARK: - Stored properties

    /// All results kept after cap (max 10 000).
    private(set) var allResults: [SearchResult] = []

    /// How many results are currently visible (pagination).
    private(set) var visibleCount: Int = 0

    /// Currently selected row index (nil = no selection).
    private(set) var selectedIndex: Int? = nil

    /// Whether the original result set exceeded the cap.
    private(set) var wasCapped: Bool = false

    /// Current search query (for match highlighting in rows).
    var currentQuery: String = ""

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

    // MARK: - Mutation

    /// Set a new result set (new query). Resets pagination and selection.
    func setResults(_ results: [SearchResult]) {
        wasCapped = results.count > Self.maxResults
        allResults = Array(results.prefix(Self.maxResults))
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
            // First press: select first or last item
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
}

// MARK: - ResultsListView

/// Displays search results in a virtualized list with keyboard navigation.
struct ResultsListView: View {

    @Bindable var state: ResultsListState
    @FocusState private var isFocused: Bool
    private let quickLookController = QuickLookPreviewController()

    var body: some View {
        Group {
            if state.isEmpty {
                emptyState
            } else {
                resultList
            }
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            if quickLookController.isPreviewOpen {
                _ = quickLookController.navigatePreview(
                    results: state.visibleResults,
                    direction: .up
                )
            }
            state.moveSelection(down: false)
            return .handled
        }
        .onKeyPress(.downArrow) {
            if quickLookController.isPreviewOpen {
                _ = quickLookController.navigatePreview(
                    results: state.visibleResults,
                    direction: .down
                )
            }
            state.moveSelection(down: true)
            return .handled
        }
        .onKeyPress(.space) {
            quickLookController.togglePreview(
                results: state.visibleResults,
                selectedIndex: state.selectedIndex
            )
            return .handled
        }
        .onKeyPress(.escape) {
            if quickLookController.isPreviewOpen {
                quickLookController.closePreview()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Text(state.statusText)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Result List

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(state.visibleResults.enumerated()), id: \.element.record.id) { index, result in
                    ResultRowView(
                        result: result,
                        isSelected: index == state.selectedIndex,
                        query: state.currentQuery
                    )
                    .accessibilityIdentifier("result_row_\(index)")
                }

                // Load-more footer
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

                // Cap warning
                if state.isCapped {
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("cap_warning")
                }
            }
        }
    }
}