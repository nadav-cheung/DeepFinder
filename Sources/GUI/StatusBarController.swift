import AppKit
import Foundation
import OSLog

// MARK: - StatusBarControllerActions

/// Protocol abstracting status bar controller actions for testability.
///
/// Production `StatusBarController` implements this. Tests inject mocks
/// to verify toggle/search/quit behavior without creating real NSStatusItems.
@MainActor
protocol StatusBarControllerActions {
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
/// Clicking the status bar icon shows a dropdown menu with Search, Settings,
/// Check for Updates, and Quit. The button tooltip reflects the current index
/// status.
///
/// Inherits `NSObject` for `@objc` selector support. `@MainActor` because all
/// NSStatusItem operations must run on the main thread.
@MainActor
public final class StatusBarController: NSObject, StatusBarControllerActions {

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.nadav.deepfinder.daemon", category: "status-bar")

    // MARK: - State

    /// The managed NSStatusItem.
    private var statusItem: NSStatusItem?

    /// Current index status badge.
    private(set) var indexStatus: IndexStatusBadge = .idle

    // MARK: - Dependencies

    /// Closure invoked when "Search" is selected from the menu.
    private let onShowSearchPanel: () -> Void

    /// Closure invoked when the search panel should be hidden.
    private let onHideSearchPanel: () -> Void

    /// Closure invoked when "Settings" is selected from the menu.
    private let onOpenSettings: () -> Void

    /// Closure invoked when "Quit" is selected from the menu.
    private let onQuit: () -> Void

    // MARK: - Init

    /// Create a new status bar controller.
    ///
    /// - Parameters:
    ///   - onShowSearchPanel: Called when "Search" is selected from the menu.
    ///   - onHideSearchPanel: Called when the search panel should be hidden.
    ///   - onOpenSettings: Called when "Settings" is selected from the menu.
    ///   - onQuit: Called when "Quit" is selected from the menu.
    public init(
        onShowSearchPanel: @escaping () -> Void = {},
        onHideSearchPanel: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.onShowSearchPanel = onShowSearchPanel
        self.onHideSearchPanel = onHideSearchPanel
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        super.init()
    }

    // MARK: - Lifecycle

    /// Install the status bar item into the menu bar.
    ///
    /// Creates an NSStatusItem with a magnifying glass icon. Clicking the icon
    /// shows a dropdown menu with Search, Settings, Check for Updates, and Quit.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: Product.name)
            button.image?.size = NSSize(width: 18, height: 18)
            button.toolTip = indexStatus.tooltip
        }

        // NSStatusItem.menu tells macOS to show this dropdown when the icon is
        // clicked. Must be set on the statusItem, NOT on button.menu (which only
        // controls the right-click context menu).
        item.menu = buildMenu()
        logger.info("Status bar item installed")
    }

    /// Remove the status bar item from the menu bar.
    func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            self.statusItem = nil
            logger.info("Status bar item removed")
        }
    }

    // MARK: - Index Status

    /// Update the index status badge displayed in the status bar.
    ///
    /// Updates the button tooltip and icon to reflect the current index state.
    func updateIndexStatus(_ status: IndexStatusBadge) {
        guard status != indexStatus else { return }
        logger.info("Index status: \(self.indexStatus.rawValue) -> \(status.rawValue)")
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

    // MARK: - Menu

    /// Build the dropdown menu attached to the status bar item.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let searchItem = NSMenuItem(
            title: "搜索",
            action: #selector(contextSearchClicked),
            keyEquivalent: "k"
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

        let updateItem = NSMenuItem(
            title: "检查更新...",
            action: #selector(contextCheckUpdatesClicked),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(Product.name)",
            action: #selector(contextQuitClicked),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
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

    @objc private func contextCheckUpdatesClicked() {
        NSWorkspace.shared.open(UpdateConstants.updateURL)
    }
}

// MARK: - Update URL

private enum UpdateConstants {
    /// GitHub Releases page for checking new versions.
    static let updateURL = URL(string: "https://github.com/nadav-cheung/DeepFinder/releases")!
}
