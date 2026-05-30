import AppKit
import Foundation
import Combine

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
    func search() async {
        let query = searchText
        guard !query.isEmpty else {
            results = []
            hasSearched = false
            isLoading = false
            return
        }

        isLoading = true
        selectedIndex = nil

        do {
            let response = try await ipcClient.send(.query(query, limit: nil))
            switch response {
            case .results(let searchResults, _):
                results = searchResults
            case .error:
                results = []
            default:
                results = []
            }
        } catch {
            results = []
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
