import Testing
import Foundation
import DeepFinderIndex
@testable import DeepFinderGUILib

@Suite("StatusBarController")
struct StatusBarControllerTests {

    // MARK: - Helpers

    /// Records which actions were called during a test.
    @MainActor
    private final class ActionRecorder: @unchecked Sendable {
        var showCalled = false
        var hideCalled = false
        var settingsCalled = false
        var quitCalled = false
    }

    /// Create a StatusBarController with an ActionRecorder tracking all callbacks.
    @MainActor
    private func makeController(recorder: ActionRecorder) -> StatusBarController {
        StatusBarController(
            onShowSearchPanel: { recorder.showCalled = true },
            onHideSearchPanel: { recorder.hideCalled = true },
            onOpenSettings: { recorder.settingsCalled = true },
            onQuit: { recorder.quitCalled = true }
        )
    }

    // MARK: - 1. Initial index status is idle

    @Test("Initial index status is idle")
    @MainActor
    func testInitialIndexStatusIsIdle() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)
        #expect(controller.indexStatus == .idle)
    }

    // MARK: - 2. showSearchPanel invokes callback

    @Test("showSearchPanel invokes callback")
    @MainActor
    func testShowSearchPanelInvokesCallback() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)
        controller.showSearchPanel()
        #expect(recorder.showCalled == true)
        #expect(recorder.settingsCalled == false)
        #expect(recorder.quitCalled == false)
    }

    // MARK: - 3. hideSearchPanel invokes callback

    @Test("hideSearchPanel invokes callback")
    @MainActor
    func testHideSearchPanelInvokesCallback() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)
        controller.hideSearchPanel()
        #expect(recorder.hideCalled == true)
    }

    // MARK: - 4. openSettings invokes callback

    @Test("openSettings invokes callback")
    @MainActor
    func testOpenSettingsInvokesCallback() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)
        controller.openSettings()
        #expect(recorder.settingsCalled == true)
        #expect(recorder.quitCalled == false)
    }

    // MARK: - 5. quitApp invokes callback

    @Test("quitApp invokes callback")
    @MainActor
    func testQuitAppInvokesCallback() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)
        controller.quitApp()
        #expect(recorder.quitCalled == true)
        #expect(recorder.settingsCalled == false)
    }

    // MARK: - 6. updateIndexStatus with badge

    @Test("updateIndexStatus with badge updates status")
    @MainActor
    func testUpdateIndexStatusWithBadge() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)

        controller.updateIndexStatus(.indexing)
        #expect(controller.indexStatus == .indexing)

        controller.updateIndexStatus(.live)
        #expect(controller.indexStatus == .live)

        controller.updateIndexStatus(.error)
        #expect(controller.indexStatus == .error)

        controller.updateIndexStatus(.idle)
        #expect(controller.indexStatus == .idle)
    }

    // MARK: - 7. updateIndexStatus from state string

    @Test("updateIndexStatus from state string maps correctly")
    @MainActor
    func testUpdateIndexStatusFromStateString() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)

        controller.updateIndexStatus(stateString: "live")
        #expect(controller.indexStatus == .live)

        controller.updateIndexStatus(stateString: "verifying")
        #expect(controller.indexStatus == .indexing)

        controller.updateIndexStatus(stateString: "polling")
        #expect(controller.indexStatus == .indexing)

        controller.updateIndexStatus(stateString: "error")
        #expect(controller.indexStatus == .error)

        controller.updateIndexStatus(stateString: "stale")
        #expect(controller.indexStatus == .idle)

        controller.updateIndexStatus(stateString: "unknown")
        #expect(controller.indexStatus == .idle)
    }

    // MARK: - 8. Install and remove lifecycle

    @Test("Install and remove lifecycle do not crash")
    @MainActor
    func testInstallRemoveLifecycle() {
        let recorder = ActionRecorder()
        let controller = makeController(recorder: recorder)

        // Install should not crash.
        controller.install()

        // Remove should not crash.
        controller.remove()

        // Double remove should not crash.
        controller.remove()
    }

    // MARK: - 9. Multiple show calls

    @Test("Multiple showSearchPanel calls each invoke callback")
    @MainActor
    func testMultipleShowCalls() {
        var count = 0
        let controller = StatusBarController(
            onShowSearchPanel: { count += 1 }
        )

        controller.showSearchPanel()
        controller.showSearchPanel()
        controller.showSearchPanel()

        #expect(count == 3)
    }

    // MARK: - 10. Default closures do not crash

    @Test("Default closures do not crash")
    @MainActor
    func testDefaultClosuresDoNotCrash() {
        let controller = StatusBarController()

        // All actions with default empty closures should be safe.
        controller.showSearchPanel()
        controller.hideSearchPanel()
        controller.openSettings()
        controller.quitApp()
    }

    // MARK: - 11. Update status after install

    @Test("Update index status after install does not crash")
    @MainActor
    func testUpdateStatusAfterInstall() {
        let controller = StatusBarController()
        controller.install()
        controller.updateIndexStatus(.live)
        #expect(controller.indexStatus == .live)
        controller.remove()
    }

    // MARK: - 12. Update status before install does not crash

    @Test("Update index status before install does not crash")
    @MainActor
    func testUpdateStatusBeforeInstall() {
        let controller = StatusBarController()
        controller.updateIndexStatus(.indexing)
        #expect(controller.indexStatus == .indexing)
    }
}

// MARK: - IndexStatusBadge Tests

@Suite("IndexStatusBadge")
struct IndexStatusBadgeTests {

    // MARK: - 1. State string mapping

    @Test("State string mapping produces correct badge")
    func testStateStringMapping() {
        #expect(IndexStatusBadge(stateString: "live") == .live)
        #expect(IndexStatusBadge(stateString: "LIVE") == .live)
        #expect(IndexStatusBadge(stateString: "Live") == .live)
        #expect(IndexStatusBadge(stateString: "verifying") == .indexing)
        #expect(IndexStatusBadge(stateString: "polling") == .indexing)
        #expect(IndexStatusBadge(stateString: "error") == .error)
        #expect(IndexStatusBadge(stateString: "stale") == .idle)
        #expect(IndexStatusBadge(stateString: "unknown") == .idle)
        #expect(IndexStatusBadge(stateString: "") == .idle)
    }

    // MARK: - 2. Icon names are valid SF Symbols

    @Test("Icon names are non-empty strings")
    func testIconNamesAreNonEmpty() {
        for badge: IndexStatusBadge in [.idle, .indexing, .live, .error] {
            #expect(!badge.iconName.isEmpty)
        }
    }

    // MARK: - 3. Tooltips contain product name

    @Test("Tooltips contain product name")
    func testTooltipsContainProductName() {
        for badge: IndexStatusBadge in [.idle, .indexing, .live, .error] {
            #expect(badge.tooltip.contains(Product.name))
        }
    }

    // MARK: - 4. Raw value round-trip

    @Test("Raw value round-trip preserves badge")
    func testRawValueRoundTrip() {
        for badge: IndexStatusBadge in [.idle, .indexing, .live, .error] {
            let raw = badge.rawValue
            let restored = IndexStatusBadge(rawValue: raw)
            #expect(restored == badge)
        }
    }
}
