import SwiftUI
import AppKit
import Foundation
import Combine
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - SearchErrorState

/// Error states surfaced to the search panel UI.
///
/// Distinguishes between an empty result set (successful search, nothing found),
/// a daemon connectivity issue, and a processing error from the daemon.
public enum SearchErrorState: Sendable, Equatable {
    /// No results found for the given query. This is a valid search outcome,
    /// not a failure — the query completed successfully but matched nothing.
    case noResults
    /// The daemon is not running or the IPC connection was lost.
    case daemonDisconnected
    /// The daemon reported an error while processing the query.
    case searchError(String)
}

// MARK: - SearchViewModel

/// View model bridging the GUI search panel to the daemon via IPC.
///
/// Manages search text, results, loading state, and selection.
/// Uses `IPCClientProtocol` for daemon communication (testable via mocks)
/// and `WorkspaceProtocol` for file open/reveal operations.
///
/// `@MainActor` because it is an `ObservableObject` driving SwiftUI views,
/// which require synchronous access to published properties in the view body.
/// IPC calls are still async; all state mutations happen on the main actor.
@MainActor
public final class SearchViewModel: ObservableObject {

    // MARK: - Published State

    @Published var searchText: String = ""
    @Published var results: [SearchResult] = []
    @Published var isLoading: Bool = false
    @Published var showSpinner: Bool = false
    @Published var searchTimedOut: Bool = false
    @Published var selectedIndex: Int?
    @Published var hasSearched: Bool = false
    @Published var errorState: SearchErrorState?

    /// Toast message displayed as a transient overlay. Set to a non-nil string
    /// to present a toast; it auto-dismisses after 1.5 seconds.
    /// REQ-3.2-27: "已复制路径" feedback after Cmd+C.
    @Published var toastMessage: String? = nil

    /// REQ-3.2-02: Whether the history dropdown overlay is visible.
    @Published var showHistoryDropdown: Bool = false

    /// Validates the current search query syntax and returns an error description
    /// if the query is malformed (e.g., unbalanced quotes, incomplete operators).
    public var syntaxError: String? {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }

        // Check for unbalanced quotes
        let quoteCount = query.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            return "Unbalanced quotes in query"
        }

        // Check for incomplete operators (AND/OR/NOT at end of query)
        let upper = query.uppercased()
        let trailingOps = ["AND", "OR", "NOT"]
        for op in trailingOps {
            if upper.hasSuffix(" \(op)") || upper == op {
                return "Incomplete operator: \(op)"
            }
        }

        return nil
    }

    // MARK: - History & Access Stores

    /// Search query history for the history dropdown. REQ-3.2-02.
    public let searchHistory = SearchHistoryStore()

    /// File access frequency tracker for ranking boost. REQ-3.2-33.
    public let accessHistory = AccessHistoryStore()

    // MARK: - Dependencies

    private let ipcClient: IPCClientProtocol
    public let workspace: WorkspaceProtocol

    /// Index health monitor for displaying banners and progress in the search panel.
    public weak var indexHealthMonitor: IndexHealthMonitor?

    /// Whether Full Disk Access is currently granted.
    public var fdaGranted: Bool { PermissionChecker.isFDAGranted() }

    /// Whether a software update is available. Synced to views for update banners.
    @Published var updateAvailable: Bool = false

    // MARK: - Stored Tasks (prevent races and leaks)

    /// Stored reference to the search task triggered from history, so we can
    /// cancel the previous search before starting a new one.
    private var historySearchTask: Task<Void, Never>?

    /// Stored reference to the toast auto-dismiss task, so a new toast cancels
    /// the previous dismiss timer.
    private var toastDismissTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        ipcClient: IPCClientProtocol,
        workspace: WorkspaceProtocol? = nil
    ) {
        self.ipcClient = ipcClient
        self.workspace = workspace ?? NSWorkspace.shared
    }

    // MARK: - Search

    /// Send the current search text to the daemon and store results.
    ///
    /// Sets `errorState` to distinguish between empty results (`.noResults`),
    /// daemon connectivity failures (`.daemonDisconnected`), and query errors
    /// (`.searchError`). On success with results, `errorState` stays `nil`.
    ///
    /// REQ-3.2-02: Records the query in search history when results are found.
    public func search() async {
        let query = searchText
        guard !query.isEmpty else {
            results = []
            hasSearched = false
            isLoading = false
            showSpinner = false
            searchTimedOut = false
            errorState = nil
            return
        }

        isLoading = true
        showSpinner = false
        searchTimedOut = false
        selectedIndex = nil
        errorState = nil

        // REQ-3.2-04: spinner only appears if search takes > 50ms.
        let spinnerTask = Task {
            try? await Task.sleep(for: .seconds(0.05))
            guard !Task.isCancelled else { return }
            showSpinner = isLoading
        }

        // REQ-3.2-04: timeout after 10 seconds.
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            searchTimedOut = true
        }

        do {
            let response = try await ipcClient.send(.query(query, limit: nil))
            switch response {
            case .results(let searchResults, _):
                // REQ-3.2-33: apply access history boosting before storing results.
                let boostedPaths = accessHistory.sortedPaths()
                let boostedSet = Set(boostedPaths.prefix(100))
                results = searchResults.sorted { a, b in
                    let aBoosted = boostedSet.contains(a.record.path)
                    let bBoosted = boostedSet.contains(b.record.path)
                    if aBoosted != bBoosted { return aBoosted }
                    return false // preserve original order for non-boosted
                }
                errorState = searchResults.isEmpty ? .noResults : nil
                // REQ-3.2-02: persist search history on successful non-empty results.
                if !searchResults.isEmpty {
                    searchHistory.addEntry(query)
                }
            case .error(let ipcError):
                results = []
                switch ipcError {
                case .daemonNotReady:
                    errorState = .daemonDisconnected
                case .queryError(let message):
                    errorState = .searchError(message)
                case .invalidRequest(let message):
                    errorState = .searchError(message)
                case .permissionDenied(let message):
                    errorState = .searchError(message)
                case .incompatibleProtocolVersion:
                    errorState = .searchError(
                        "Protocol version mismatch: your client is newer than the daemon. Please update the daemon."
                    )
                }
            default:
                results = []
            }
        } catch is IPCClientError {
            results = []
            errorState = .daemonDisconnected
        } catch {
            results = []
            errorState = .searchError(error.localizedDescription)
        }

        spinnerTask.cancel()
        timeoutTask.cancel()
        isLoading = false
        showSpinner = false
        searchTimedOut = false
        hasSearched = true
    }

    // MARK: - Actions

    /// Open the currently selected file with the default application.
    /// Returns `true` if a file was opened, `false` if nothing was selected.
    ///
    /// REQ-3.2-33: records the file access for ranking boost.
    public func openSelected() -> Bool {
        guard let idx = selectedIndex, idx >= 0, idx < results.count else {
            return false
        }
        let path = results[idx].record.path
        let success = workspace.open(path)
        if success {
            accessHistory.recordAccess(path)
        }
        return success
    }

    /// Reveal the currently selected file in Finder.
    /// Returns `true` if a file was revealed, `false` if nothing was selected.
    public func revealSelected() -> Bool {
        guard let idx = selectedIndex, idx >= 0, idx < results.count else {
            return false
        }
        let path = results[idx].record.path
        return workspace.selectFile(path)
    }

    // MARK: - Search from History (REQ-3.2-02)

    /// Sets the search text to a history query and triggers a search immediately.
    public func searchFromHistory(_ query: String) {
        searchText = query
        historySearchTask?.cancel()
        historySearchTask = Task { await search() }
    }

    /// Toggle history dropdown visibility. Only activates when search is empty.
    public func toggleHistoryDropdown() {
        if showHistoryDropdown {
            showHistoryDropdown = false
        } else if searchText.isEmpty {
            showHistoryDropdown = true
        }
    }

    // MARK: - Toast (REQ-3.2-27)

    /// Shows a transient toast message that auto-dismisses after 1.5 seconds.
    public func showToast(_ message: String) {
        toastMessage = message
        toastDismissTask?.cancel()
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { self.toastMessage = nil }
        }
    }

    /// Cancel all stored tasks. Call when the view model is no longer needed.
    public func cancelAllTasks() {
        historySearchTask?.cancel()
        toastDismissTask?.cancel()
    }
}
