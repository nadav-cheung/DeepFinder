import AppKit
import Foundation

// MARK: - ContextMenuActions

/// Protocol abstracting context menu file actions for testability.
///
/// Production uses `ResultContextMenuHandler` which delegates to NSWorkspace
/// and NSPasteboard. Tests inject `MockContextMenuActions` to verify behavior
/// without touching the real file system or clipboard.
///
/// `@MainActor` because AppKit operations (NSWorkspace, NSPasteboard) must
/// run on the main thread.
@MainActor
protocol ContextMenuActions: Sendable {
    func open(_ path: String) -> Bool
    func reveal(_ path: String) -> Bool
    func copyPath(_ path: String) -> Bool
    func getInfo(_ path: String) -> Bool
}

// MARK: - ResultContextMenuHandler

/// Production handler for context menu actions.
///
/// Delegates to `NSWorkspace` for open/reveal/get-info and to
/// `NSPasteboard` for clipboard operations.
@MainActor
final class ResultContextMenuHandler: ContextMenuActions {

    func open(_ path: String) -> Bool {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ path: String) -> Bool {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func copyPath(_ path: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(path, forType: .fileURL)
    }

    func getInfo(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        // Activate Finder first so the Get Info window is visible
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.open(finderURL)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}

// MARK: - ResultContextMenu

/// Builds an `NSMenu` for right-click actions on a search result.
///
/// REQ-2.0-12: Right-click context menu on result rows with Open, Reveal in
/// Finder, Copy Path, and Get Info actions.
///
/// Usage in SwiftUI:
/// ```swift
/// .contextMenu { ResultContextMenu.menuItems(for: result, actions: handler) }
/// ```
///
/// Or with the `NSMenu` representation:
/// ```swift
/// let menu = ResultContextMenu.buildMenu(path: path, actions: handler)
/// ```
enum ResultContextMenu {

    // MARK: - Menu Item Identifiers

    /// Identifiers for context menu items, used for testing and accessibility.
    enum MenuItem: String, Sendable, CaseIterable {
        case open
        case reveal
        case copyPath
        case getInfo

        /// Localized display title.
        var title: String {
            switch self {
            case .open: "Open"
            case .reveal: "Reveal in Finder"
            case .copyPath: "Copy Path"
            case .getInfo: "Get Info"
            }
        }
    }

    // MARK: - NSMenu Construction

    /// Build an `NSMenu` with all four actions wired to the given handler.
    ///
    /// - Parameters:
    ///   - path: File path the menu operates on.
    ///   - actions: Handler that executes each action.
    /// - Returns: A configured `NSMenu`.
    @MainActor
    static func buildMenu(path: String, actions: ContextMenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.title = "File Actions"

        // Retain targets strongly — NSMenuItem.target is weak.
        var targets: [ContextMenuTarget] = []

        for item in MenuItem.allCases {
            let target = ContextMenuTarget(item: item, path: path, actions: actions)
            targets.append(target)
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(ContextMenuTarget.performAction),
                keyEquivalent: ""
            )
            menuItem.target = target
            menuItem.setAccessibilityIdentifier(item.rawValue)
            menu.addItem(menuItem)
        }

        // Store targets strongly via objc_setAssociatedObject so they remain
        // alive for the lifetime of the menu (NSMenuItem.target is weak).
        objc_setAssociatedObject(menu, &AssociatedKeys.targets, targets, .OBJC_ASSOCIATION_RETAIN)

        return menu
    }

    // MARK: - Associated Object Keys

    private enum AssociatedKeys {
        nonisolated(unsafe) static var targets = "ResultContextMenu.targets"
    }

    // MARK: - SwiftUI Context Menu ViewBuilder

    /// Returns SwiftUI Button views for use inside `.contextMenu { }`.
    ///
    /// - Parameters:
    ///   - path: File path the actions operate on.
    ///   - actions: Handler that executes each action.
    /// - Returns: An array of closures that produce SwiftUI Buttons.
    @MainActor
    static func menuItems(
        for path: String,
        actions: ContextMenuActions
    ) -> [(label: String, id: String, action: () -> Void)] {
        MenuItem.allCases.map { item in
            (label: item.title, id: item.rawValue, action: {
                perform(item: item, path: path, actions: actions)
            })
        }
    }

    // MARK: - Action Dispatch

    /// Execute a specific context menu action.
    ///
    /// Exposed internally for testability — tests can call this directly
    /// with a mock handler and verify the correct method was invoked.
    @MainActor
    static func perform(
        item: MenuItem,
        path: String,
        actions: ContextMenuActions
    ) {
        switch item {
        case .open:
            _ = actions.open(path)
        case .reveal:
            _ = actions.reveal(path)
        case .copyPath:
            _ = actions.copyPath(path)
        case .getInfo:
            _ = actions.getInfo(path)
        }
    }
}

// MARK: - ContextMenuTarget

/// Objective-C compatible target for NSMenuItem actions.
///
/// Holds a strong reference to the action handler and path so the menu item
/// can invoke the correct action when clicked.
@MainActor
final class ContextMenuTarget: NSObject {

    let item: ResultContextMenu.MenuItem
    let path: String
    let actions: ContextMenuActions

    init(item: ResultContextMenu.MenuItem, path: String, actions: ContextMenuActions) {
        self.item = item
        self.path = path
        self.actions = actions
    }

    @objc func performAction() {
        ResultContextMenu.perform(item: item, path: path, actions: actions)
    }
}
