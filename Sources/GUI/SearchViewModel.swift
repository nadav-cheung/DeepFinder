import AppKit
import Foundation
import Combine

// MARK: - SearchErrorState

/// Error states surfaced to the search panel UI.
///
/// Distinguishes between an empty result set (successful search, nothing found),
/// a daemon connectivity issue, and a processing error from the daemon.
enum SearchErrorState: Sendable, Equatable {
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
final class SearchViewModel: ObservableObject {

    // MARK: - Published State

    @Published var searchText: String = ""
    @Published var results: [SearchResult] = []
    @Published var isLoading: Bool = false
    @Published var selectedIndex: Int?
    @Published var hasSearched: Bool = false
    @Published var errorState: SearchErrorState?

    // MARK: - Dependencies

    private let ipcClient: IPCClientProtocol
    let workspace: WorkspaceProtocol

    // MARK: - Init

    init(
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
    func search() async {
        let query = searchText
        guard !query.isEmpty else {
            results = []
            hasSearched = false
            isLoading = false
            errorState = nil
            return
        }

        isLoading = true
        selectedIndex = nil
        errorState = nil

        do {
            let response = try await ipcClient.send(.query(query, limit: nil))
            switch response {
            case .results(let searchResults, _):
                results = searchResults
                errorState = searchResults.isEmpty ? .noResults : nil
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

        isLoading = false
        hasSearched = true
    }

    // MARK: - Actions

    /// Open the currently selected file with the default application.
    /// Returns `true` if a file was opened, `false` if nothing was selected.
    func openSelected() -> Bool {
        guard let idx = selectedIndex, idx >= 0, idx < results.count else {
            return false
        }
        let path = results[idx].record.path
        return workspace.open(path)
    }

    /// Reveal the currently selected file in Finder.
    /// Returns `true` if a file was revealed, `false` if nothing was selected.
    func revealSelected() -> Bool {
        guard let idx = selectedIndex, idx >= 0, idx < results.count else {
            return false
        }
        let path = results[idx].record.path
        return workspace.selectFile(path)
    }
}
