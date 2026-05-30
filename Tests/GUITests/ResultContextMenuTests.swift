import Testing
import Foundation
@testable import DeepFinder

@Suite("ResultContextMenu")
struct ResultContextMenuTests {

    // MARK: - Mock

    /// Records which actions were called and with what path.
    @MainActor
    final class MockContextMenuActions: ContextMenuActions, @unchecked Sendable {
        var openCalled = false
        var revealCalled = false
        var copyPathCalled = false
        var getInfoCalled = false
        var lastPath: String?

        var openResult: Bool = true
        var revealResult: Bool = true
        var copyPathResult: Bool = true
        var getInfoResult: Bool = true

        func open(_ path: String) -> Bool {
            openCalled = true
            lastPath = path
            return openResult
        }

        func reveal(_ path: String) -> Bool {
            revealCalled = true
            lastPath = path
            return revealResult
        }

        func copyPath(_ path: String) -> Bool {
            copyPathCalled = true
            lastPath = path
            return copyPathResult
        }

        func getInfo(_ path: String) -> Bool {
            getInfoCalled = true
            lastPath = path
            return getInfoResult
        }

        func reset() {
            openCalled = false
            revealCalled = false
            copyPathCalled = false
            getInfoCalled = false
            lastPath = nil
        }
    }

    // MARK: - Helpers

    private let testPath = "/Users/test/Documents/report.pdf"

    // MARK: - MenuItem titles

    @Test("All menu items have non-empty titles")
    func menuItemTitles() {
        for item in ResultContextMenu.MenuItem.allCases {
            #expect(!item.title.isEmpty)
        }
    }

    @Test("Menu items have four cases in expected order")
    func menuItemCount() {
        let items = ResultContextMenu.MenuItem.allCases
        #expect(items.count == 4)
        #expect(items[0] == .open)
        #expect(items[1] == .reveal)
        #expect(items[2] == .copyPath)
        #expect(items[3] == .getInfo)
    }

    // MARK: - perform dispatches to correct action

    @Test("Perform open dispatches to open action")
    @MainActor
    func performOpen() {
        let mock = MockContextMenuActions()
        ResultContextMenu.perform(item: .open, path: testPath, actions: mock)
        #expect(mock.openCalled)
        #expect(mock.lastPath == testPath)
        #expect(!mock.revealCalled)
        #expect(!mock.copyPathCalled)
        #expect(!mock.getInfoCalled)
    }

    @Test("Perform reveal dispatches to reveal action")
    @MainActor
    func performReveal() {
        let mock = MockContextMenuActions()
        ResultContextMenu.perform(item: .reveal, path: testPath, actions: mock)
        #expect(mock.revealCalled)
        #expect(mock.lastPath == testPath)
        #expect(!mock.openCalled)
    }

    @Test("Perform copyPath dispatches to copyPath action")
    @MainActor
    func performCopyPath() {
        let mock = MockContextMenuActions()
        ResultContextMenu.perform(item: .copyPath, path: testPath, actions: mock)
        #expect(mock.copyPathCalled)
        #expect(mock.lastPath == testPath)
        #expect(!mock.openCalled)
    }

    @Test("Perform getInfo dispatches to getInfo action")
    @MainActor
    func performGetInfo() {
        let mock = MockContextMenuActions()
        ResultContextMenu.perform(item: .getInfo, path: testPath, actions: mock)
        #expect(mock.getInfoCalled)
        #expect(mock.lastPath == testPath)
        #expect(!mock.openCalled)
    }

    // MARK: - menuItems returns correct entries

    @Test("menuItems returns four entries with correct labels and ids")
    @MainActor
    func menuItemsStructure() {
        let mock = MockContextMenuActions()
        let items = ResultContextMenu.menuItems(for: testPath, actions: mock)
        #expect(items.count == 4)
        #expect(items[0].label == "Open")
        #expect(items[0].id == "open")
        #expect(items[1].label == "Reveal in Finder")
        #expect(items[1].id == "reveal")
        #expect(items[2].label == "Copy Path")
        #expect(items[2].id == "copyPath")
        #expect(items[3].label == "Get Info")
        #expect(items[3].id == "getInfo")
    }

    @Test("menuItems action closures invoke correct handler method")
    @MainActor
    func menuItemsActionClosures() {
        let mock = MockContextMenuActions()

        // Invoke each closure
        for item in ResultContextMenu.menuItems(for: testPath, actions: mock) {
            item.action()
        }

        #expect(mock.openCalled)
        #expect(mock.revealCalled)
        #expect(mock.copyPathCalled)
        #expect(mock.getInfoCalled)
    }

    // MARK: - buildMenu creates NSMenu

    @Test("buildMenu creates menu with correct item count and accessibility ids")
    @MainActor
    func buildMenuStructure() {
        let mock = MockContextMenuActions()
        let menu = ResultContextMenu.buildMenu(path: testPath, actions: mock)

        #expect(menu.items.count == 4)
        #expect(menu.items[0].title == "Open")
        #expect(menu.items[0].accessibilityIdentifier() == "open")
        #expect(menu.items[1].title == "Reveal in Finder")
        #expect(menu.items[1].accessibilityIdentifier() == "reveal")
        #expect(menu.items[2].title == "Copy Path")
        #expect(menu.items[2].accessibilityIdentifier() == "copyPath")
        #expect(menu.items[3].title == "Get Info")
        #expect(menu.items[3].accessibilityIdentifier() == "getInfo")
    }

    @Test("buildMenu items have targets that can perform actions")
    @MainActor
    func buildMenuTargetsPerformActions() {
        let mock = MockContextMenuActions()
        let menu = ResultContextMenu.buildMenu(path: testPath, actions: mock)

        // Simulate clicking each menu item
        for menuItem in menu.items {
            guard let target = menuItem.target as? ContextMenuTarget else {
                Issue.record("Menu item has no ContextMenuTarget")
                continue
            }
            target.performAction()
        }

        #expect(mock.openCalled)
        #expect(mock.revealCalled)
        #expect(mock.copyPathCalled)
        #expect(mock.getInfoCalled)
    }

    // MARK: - Action return values propagate

    @Test("Failed action return value propagates")
    @MainActor
    func failedActionReturn() {
        let mock = MockContextMenuActions()
        mock.openResult = false
        let result = mock.open(testPath)
        #expect(result == false)
        #expect(mock.openCalled)
    }

    // MARK: - Different paths

    @Test("Actions receive correct path for different results")
    @MainActor
    func differentPaths() {
        let mock = MockContextMenuActions()
        let altPath = "/Volumes/Data/photos/img.jpg"

        ResultContextMenu.perform(item: .copyPath, path: altPath, actions: mock)
        #expect(mock.lastPath == altPath)

        mock.reset()

        ResultContextMenu.perform(item: .reveal, path: testPath, actions: mock)
        #expect(mock.lastPath == testPath)
    }

    // MARK: - ContextMenuTarget holds correct state

    @Test("ContextMenuTarget stores item, path, and actions")
    @MainActor
    func contextMenuTargetState() {
        let mock = MockContextMenuActions()
        let target = ContextMenuTarget(item: .copyPath, path: testPath, actions: mock)

        #expect(target.item == .copyPath)
        #expect(target.path == testPath)
    }
}
