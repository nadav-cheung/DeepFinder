import AppKit
import Foundation

// MARK: - StatusBarControllerActions

/// Protocol abstracting status bar controller actions for testability.
///
/// Production `StatusBarController` implements this. Tests inject mocks
/// to verify toggle/search/quit behavior without creating real NSStatusItems.
@MainActor
protocol StatusBarControllerActions: Sendable {
    func toggleSearchPanel()
    func showSearchPanel()
    func hideSearchPanel()
    func openSettings()
    func quitApp()
}

// MARK: - IndexStatusBadge

/// Index status badge displayed in the menu bar.
///
/// Maps index state strings to a human-readable label and icon.
/// The badge is displayed as the status item's button tooltip.
enum IndexStatusBadge: String, Sendable, Equatable {
    case idle
    case indexing
    case live
    case error

    /// Create from daemon-reported index state string.
    init(stateString: String) {
        switch stateString.lowercased() {
        case "live":
            self = .live
        case "verifying", "indexing", "polling":
            self = .indexing
        case "error":
            self = .error
        default:
            self = .idle
        }
    }

    /// SF Symbol name for the status bar icon overlay.
    var iconName: String {
        switch self {
        case .idle: "magnifyingglass"
        case .indexing: "arrow.trianglehead.2.clockwise"
        case .live: "magnifyingglass"
        case .error: "exclamationmark.triangle"
        }
    }

    /// Tooltip text for the status bar item.
    var tooltip: String {
        switch self {
        case .idle: "\(Product.name) — Idle"
        case .indexing: "\(Product.name) — Indexing..."
        case .live: "\(Product.name) — Ready"
        case .error: "\(Product.name) — Index Error"
        }
    }
}

// MARK: - StatusBarController

/// Manages the NSStatusItem in the macOS menu bar.
///
/// REQ-2.0-08: Menu bar icon, click toggles search panel, right-click menu
/// with Search/Settings/Quit, index status badge.
///
/// The status bar icon is always visible. Left-click toggles the search panel.
/// Right-click shows a context menu with Search, Settings, and Quit options.
/// The button tooltip reflects the current index status.
///
/// `@MainActor` because all NSStatusItem operations must run on the main thread.
@MainActor
final class StatusBarController: StatusBarControllerActions, @unchecked Sendable {

    // MARK: - State

    /// The managed NSStatusItem.
    private var statusItem: NSStatusItem?

    /// Current index status badge.
    private(set) var indexStatus: IndexStatusBadge = .idle

    // MARK: - Dependencies

    /// Closure invoked when the search panel should toggle.
    private let onToggleSearchPanel: () -> Void

    /// Closure invoked when the search panel should show.
    private let onShowSearchPanel: () -> Void

    /// Closure invoked when the search panel should hide.
    private let onHideSearchPanel: () -> Void

    /// Closure invoked when settings should open.
    private let onOpenSettings: () -> Void

    /// Closure invoked when the app should quit.
    private let onQuit: () -> Void

    // MARK: - Init

    /// Create a new status bar controller.
    ///
    /// - Parameters:
    ///   - onToggleSearchPanel: Called when the user left-clicks the status bar icon.
    ///   - onShowSearchPanel: Called when "Search" is selected from the right-click menu.
    ///   - onHideSearchPanel: Called when the search panel should be hidden.
    ///   - onOpenSettings: Called when "Settings" is selected from the right-click menu.
    ///   - onQuit: Called when "Quit" is selected from the right-click menu.
    init(
        onToggleSearchPanel: @escaping () -> Void = {},
        onShowSearchPanel: @escaping () -> Void = {},
        onHideSearchPanel: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.onToggleSearchPanel = onToggleSearchPanel
        self.onShowSearchPanel = onShowSearchPanel
        self.onHideSearchPanel = onHideSearchPanel
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    // MARK: - Lifecycle

    /// Install the status bar item into the menu bar.
    ///
    /// Creates an NSStatusItem with a magnifying glass icon. Left-click toggles
    /// the search panel. The button tooltip reflects the current index status.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: Product.name)
            button.image?.size = NSSize(width: 18, height: 18)
            button.toolTip = indexStatus.tooltip
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Remove the status bar item from the menu bar.
    func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            self.statusItem = nil
        }
    }

    // MARK: - Index Status

    /// Update the index status badge displayed in the status bar.
    ///
    /// Updates the button tooltip and icon to reflect the current index state.
    func updateIndexStatus(_ status: IndexStatusBadge) {
        self.indexStatus = status
        statusItem?.button?.toolTip = status.tooltip
        statusItem?.button?.image = NSImage(systemSymbolName: status.iconName, accessibilityDescription: Product.name)
        statusItem?.button?.image?.size = NSSize(width: 18, height: 18)
    }

    /// Update the index status from a daemon state string.
    func updateIndexStatus(stateString: String) {
        updateIndexStatus(IndexStatusBadge(stateString: stateString))
    }

    // MARK: - StatusBarControllerActions

    func toggleSearchPanel() {
        onToggleSearchPanel()
    }

    func showSearchPanel() {
        onShowSearchPanel()
    }

    func hideSearchPanel() {
        onHideSearchPanel()
    }

    func openSettings() {
        onOpenSettings()
    }

    func quitApp() {
        onQuit()
    }

    // MARK: - Click Handler

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp?.currentEvent else {
            // Fallback: treat as left click (toggle).
            toggleSearchPanel()
            return
        }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleSearchPanel()
        }
    }

    // MARK: - Context Menu

    /// Build and show the right-click context menu.
    private func showContextMenu() {
        let menu = NSMenu()

        let searchItem = NSMenuItem(
            title: "Search",
            action: #selector(contextSearchClicked),
            keyEquivalent: ""
        )
        searchItem.target = self
        menu.addItem(searchItem)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(contextSettingsClicked),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(Product.name)",
            action: #selector(contextQuitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.button?.menu = menu
        // NSStatusItem button menu auto-shows on click; we set it here
        // and clear it after to avoid persisting.
        // A slight delay to let the menu present before clearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.statusItem?.button?.menu = nil
        }
    }

    @objc private func contextSearchClicked() {
        showSearchPanel()
    }

    @objc private func contextSettingsClicked() {
        openSettings()
    }

    @objc private func contextQuitClicked() {
        quitApp()
    }
}
