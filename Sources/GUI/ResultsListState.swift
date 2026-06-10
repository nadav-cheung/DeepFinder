import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - ResultsListState

/// Observable state driving ResultsListView.
/// Extracted from the view for unit-testability without a host app.
/// All mutation methods are value-semantic on @Observable properties.
@Observable
final class ResultsListState {

    // MARK: - Constants

    public static let pageSize = 100
    public static let maxResults = Constants.GUI.maxResults

    /// Minimum number of rows the list should display.
    /// REQ-3.2-07: ensures at least 20 rows are visible.
    public static let minVisibleRows = 20

    /// Fixed row height in points.
    /// REQ-3.2-14: constant height enables virtual scroll offset calculation.
    public static let rowHeight: CGFloat = 40

    // MARK: - Stored properties

    /// All results kept after cap (max 10 000).
    private(set) var allResults: [SearchResult] = []

    /// How many results are currently visible (pagination).
    private(set) var visibleCount: Int = 0

    /// Currently selected row index (nil = no selection).
    private(set) var selectedIndex: Int? = nil

    /// Sets the selected index directly (e.g. from mouse click).
    public func setSelectedIndex(_ index: Int?) {
        selectedIndex = index
    }

    /// Whether the original result set exceeded the cap.
    private(set) var wasCapped: Bool = false

    /// Current search query (for match highlighting in rows).
    public var currentQuery: String = ""

    /// Total result count as reported by the input layer.
    /// May differ from `allResults.count` when results are capped.
    public var totalResultCount: Int = 0

    // MARK: - Derived

    /// Results currently visible in the list.
    public var visibleResults: [SearchResult] {
        let end = min(visibleCount, allResults.count)
        return Array(allResults[..<end])
    }

    /// Whether there are more results beyond the visible window.
    public var hasMoreResults: Bool {
        visibleCount < allResults.count
    }

    /// Whether the result list is empty.
    public var isEmpty: Bool {
        allResults.isEmpty
    }

    /// Whether results were capped at maxResults.
    public var isCapped: Bool {
        wasCapped
    }

    /// Status text shown below the list.
    public var statusText: String {
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
    public var remainingCount: Int {
        allResults.count - visibleCount
    }

    /// Formatted total count with thousands separator.
    /// REQ-3.2-13: "1,234" format for the result count footer.
    public var formattedResultCount: String {
        let count = totalResultCount > 0 ? totalResultCount : allResults.count
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    // MARK: - Mutation

    /// Set a new result set (new query). Resets pagination and selection.
    public func setResults(_ results: [SearchResult]) {
        wasCapped = results.count > Self.maxResults
        allResults = Array(results.prefix(Self.maxResults))
        totalResultCount = results.count
        visibleCount = min(Self.pageSize, allResults.count)
        selectedIndex = nil
    }

    /// Show the next page of results.
    public func loadMore() {
        guard hasMoreResults else { return }
        visibleCount = min(visibleCount + Self.pageSize, allResults.count)
    }

    /// Move the selection up or down, wrapping at boundaries.
    public func moveSelection(down: Bool) {
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
    public func moveSelectionPage(down: Bool) {
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
    public func moveSelectionToGroup(categories: [ResultCategory], down: Bool) {
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
