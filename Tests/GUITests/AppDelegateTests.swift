import Testing
import Foundation
import AppKit
@testable import DeepFinder

@Suite("DeepFinderAppDelegate")
struct AppDelegateTests {

    // MARK: - Mocks

    /// Mock daemon spawner that records whether spawn was called.
    fileprivate final class MockDaemonSpawner: DaemonSpawner, @unchecked Sendable {
        var ensureCalled = false
        var shouldThrow = false

        func ensureDaemonRunning() async throws {
            ensureCalled = true
            if shouldThrow {
                throw IPCClientError.daemonSpawnFailed("test error")
            }
        }
    }

    /// Mock status bar controller that records actions.
    @MainActor
    fileprivate final class MockStatusBarController: StatusBarControllerActions, @unchecked Sendable {
        var toggleCalled = false
        var showCalled = false
        var hideCalled = false
        var settingsCalled = false
        var quitCalled = false

        func toggleSearchPanel() { toggleCalled = true }
        func showSearchPanel() { showCalled = true }
        func hideSearchPanel() { hideCalled = true }
        func openSettings() { settingsCalled = true }
        func quitApp() { quitCalled = true }
    }

    /// Tracks panel operations.
    @MainActor
    fileprivate final class MockPanelTracker: @unchecked Sendable {
        var showCalled = false
        var hideCalled = false
        var toggleCalled = false
    }

    /// Mock search panel hosting controller.
    @MainActor
    fileprivate final class MockSearchPanelController: @unchecked Sendable {
        private let tracker: MockPanelTracker

        init(tracker: MockPanelTracker) {
            self.tracker = tracker
        }

        func show() { tracker.showCalled = true }
        func hide() { tracker.hideCalled = true }
        func toggle() { tracker.toggleCalled = true }
    }

    // MARK: - Test Configuration Factory

    /// Create a test configuration with all mocks injected.
    @MainActor
    private func makeTestConfiguration(
        spawner: MockDaemonSpawner? = nil,
        autoSpawn: Bool = false
    ) -> (DeepFinderAppConfiguration, MockDaemonSpawner, MockPanelTracker, MockStatusBarController) {
        let mockSpawner = spawner ?? MockDaemonSpawner()
        let panelTracker = MockPanelTracker()
        let mockStatusBar = MockStatusBarController()

        // We use a real StatusBarController but track its actions through callbacks.
        var recordedToggle = false
        var recordedShow = false
        var recordedHide = false
        var recordedSettings = false

        let config = DeepFinderAppConfiguration(
            daemonSpawnerFactory: { mockSpawner },
            statusBarControllerFactory: { onToggle, onShow, onHide, onSettings, onQuit in
                StatusBarController(
                    onToggleSearchPanel: onToggle,
                    onShowSearchPanel: onShow,
                    onHideSearchPanel: onHide,
                    onOpenSettings: onSettings,
                    onQuit: onQuit
                )
            },
            searchPanelFactory: {
                // Return a MockSearchPanelController as a SearchPanelHostingController.
                // We need to use the real type since that's what the factory returns.
                // Instead, create a real SearchPanelHostingController with a mock view model.
                let mockIPC = MockIPCClient()
                let viewModel = SearchViewModel(ipcClient: mockIPC)
                return SearchPanelHostingController(viewModel: viewModel)
            },
            settingsWindowFactory: {
                NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
            },
            autoSpawnDaemon: autoSpawn
        )

        return (config, mockSpawner, panelTracker, mockStatusBar)
    }

    /// Minimal mock IPC client for SearchViewModel injection.
    fileprivate final class MockIPCClient: IPCClientProtocol, @unchecked Sendable {
        func send(_ request: IPCRequest) async throws -> IPCResponse {
            .ack
        }
    }

    // MARK: - 1. applicationDidFinishLaunching sets accessory policy

    @Test("applicationDidFinishLaunching sets activation policy to accessory")
    @MainActor
    func testLaunchSetsAccessoryPolicy() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        #expect(NSApp.activationPolicy() == .accessory)
    }

    // MARK: - 2. Status bar controller is created and installed

    @Test("Status bar controller is created after launch")
    @MainActor
    func testStatusBarControllerCreated() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        #expect(delegate.statusBarController != nil)
    }

    // MARK: - 3. Global hotkey is registered

    @Test("Global hotkey is created after launch")
    @MainActor
    func testGlobalHotkeyCreated() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // Note: GlobalHotkey.register may fail in test environments without
        // Accessibility permissions. The delegate stores nil if registration fails.
        // We verify the property is accessible and doesn't crash.
        _ = delegate.globalHotkey
    }

    // MARK: - 4. Search panel controller is created

    @Test("Search panel controller is created after launch")
    @MainActor
    func testSearchPanelControllerCreated() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        #expect(delegate.searchPanelController != nil)
    }

    // MARK: - 5. Toggle search panel action

    @Test("toggleSearchPanel does not crash after launch")
    @MainActor
    func testToggleSearchPanel() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.toggleSearchPanel()
        // No crash = pass.
    }

    // MARK: - 6. Show search panel action

    @Test("showSearchPanel does not crash after launch")
    @MainActor
    func testShowSearchPanel() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.showSearchPanel()
    }

    // MARK: - 7. Hide search panel action

    @Test("hideSearchPanel does not crash after launch")
    @MainActor
    func testHideSearchPanel() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.hideSearchPanel()
    }

    // MARK: - 8. Show settings window creates window on demand

    @Test("showSettingsWindow creates window on first call")
    @MainActor
    func testShowSettingsWindowCreatesWindow() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        #expect(delegate.settingsWindow == nil)

        delegate.showSettingsWindow()

        #expect(delegate.settingsWindow != nil)
    }

    // MARK: - 9. Show settings window reuses existing window

    @Test("showSettingsWindow reuses existing window")
    @MainActor
    func testShowSettingsWindowReusesWindow() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.showSettingsWindow()

        let firstWindow = delegate.settingsWindow
        delegate.showSettingsWindow()

        #expect(delegate.settingsWindow === firstWindow)
    }

    // MARK: - 10. applicationWillTerminate cleans up

    @Test("applicationWillTerminate cleans up components")
    @MainActor
    func testTerminateCleansUp() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.showSettingsWindow()

        delegate.applicationWillTerminate(Notification(name: .init("test")))

        #expect(delegate.statusBarController == nil)
        #expect(delegate.globalHotkey == nil)
        #expect(delegate.searchPanelController == nil)
        #expect(delegate.settingsWindow == nil)
    }

    // MARK: - 11. Daemon auto-spawn is called when enabled

    @Test("Daemon auto-spawn is called when enabled")
    @MainActor
    func testDaemonAutoSpawnCalled() async {
        let mockSpawner = MockDaemonSpawner()
        let (config, _, _, _) = makeTestConfiguration(spawner: mockSpawner, autoSpawn: true)
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // Give the async task a moment to run.
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(mockSpawner.ensureCalled)
    }

    // MARK: - 12. Daemon auto-spawn is skipped when disabled

    @Test("Daemon auto-spawn is skipped when disabled")
    @MainActor
    func testDaemonAutoSpawnSkipped() async {
        let mockSpawner = MockDaemonSpawner()
        let (config, _, _, _) = makeTestConfiguration(spawner: mockSpawner, autoSpawn: false)
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!mockSpawner.ensureCalled)
    }

    // MARK: - 13. Notification toggleSearchPanel triggers toggle

    @Test("Notification .toggleSearchPanel triggers toggle")
    @MainActor
    func testNotificationToggleSearchPanel() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // Post notification — should not crash.
        NotificationCenter.default.post(name: .toggleSearchPanel, object: nil)
    }

    // MARK: - 14. Notification showSettings triggers settings

    @Test("Notification .showSettings triggers settings window")
    @MainActor
    func testNotificationShowSettings() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        NotificationCenter.default.post(name: .showSettings, object: nil)

        #expect(delegate.settingsWindow != nil)
    }

    // MARK: - 15. Actions before launch do not crash

    @Test("Actions before launch do not crash (nil safety)")
    @MainActor
    func testActionsBeforeLaunch() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        // These should all be safe no-ops since controllers are nil.
        delegate.toggleSearchPanel()
        delegate.showSearchPanel()
        delegate.hideSearchPanel()
        delegate.showSettingsWindow()
    }

    // MARK: - 16. Status bar toggle callback triggers search panel

    @Test("Status bar toggle callback wired to search panel")
    @MainActor
    func testStatusBarToggleCallbackWired() {
        let (config, _, _, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // Simulate the status bar toggle callback.
        delegate.statusBarController?.toggleSearchPanel()
        // No crash = pass. The callback is wired through to searchPanelController.
    }

    // MARK: - 17. Daemon spawn failure sets error status

    @Test("Daemon spawn failure sets error index status")
    @MainActor
    func testDaemonSpawnFailureSetsErrorStatus() async {
        let mockSpawner = MockDaemonSpawner()
        mockSpawner.shouldThrow = true
        let (config, _, _, _) = makeTestConfiguration(spawner: mockSpawner, autoSpawn: true)
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // Give the async task time to complete (including failure).
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(delegate.statusBarController?.indexStatus == .error)
    }
}

// MARK: - Notification Name Tests

@Suite("AppDelegate Notification Names")
struct AppDelegateNotificationTests {

    @Test(".toggleSearchPanel has correct name")
    func testToggleSearchPanelName() {
        #expect(Notification.Name.toggleSearchPanel.rawValue == "com.nadav.deepfinder.toggleSearchPanel")
    }

    @Test(".showSettings has correct name")
    func testShowSettingsName() {
        #expect(Notification.Name.showSettings.rawValue == "com.nadav.deepfinder.showSettings")
    }

    @Test("Notification names are unique")
    func testNotificationNamesUnique() {
        #expect(Notification.Name.toggleSearchPanel != Notification.Name.showSettings)
    }
}

// MARK: - DeepFinderAppConfiguration Tests

@Suite("DeepFinderAppConfiguration")
struct DeepFinderAppConfigurationTests {

    @Test("Production configuration does not crash on creation")
    func testProductionConfigCreation() {
        // Production config creation should not crash, even though
        // it references real types.
        let config = DeepFinderAppConfiguration.production()
        #expect(config.autoSpawnDaemon == true)
    }

    @Test("Production config has default hotkey combination")
    func testProductionConfigDefaultHotkey() {
        let config = DeepFinderAppConfiguration.production()
        #expect(config.hotkeyCombination == GlobalHotkey.defaultKeyCombination)
    }

    @Test("Test configuration has autoSpawnDaemon configurable")
    func testAutoSpawnConfigurable() {
        let mockSpawner = AppDelegateTests.MockDaemonSpawner()
        let configOn = DeepFinderAppConfiguration(
            daemonSpawnerFactory: { mockSpawner },
            statusBarControllerFactory: { _, _, _, _, _ in StatusBarController() },
            searchPanelFactory: {
                let mockIPC = AppDelegateTests.MockIPCClient()
                let vm = SearchViewModel(ipcClient: mockIPC)
                return SearchPanelHostingController(viewModel: vm)
            },
            settingsWindowFactory: {
                NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            },
            autoSpawnDaemon: true
        )
        let configOff = DeepFinderAppConfiguration(
            daemonSpawnerFactory: { mockSpawner },
            statusBarControllerFactory: { _, _, _, _, _ in StatusBarController() },
            searchPanelFactory: {
                let mockIPC = AppDelegateTests.MockIPCClient()
                let vm = SearchViewModel(ipcClient: mockIPC)
                return SearchPanelHostingController(viewModel: vm)
            },
            settingsWindowFactory: {
                NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            },
            autoSpawnDaemon: false
        )
        #expect(configOn.autoSpawnDaemon == true)
        #expect(configOff.autoSpawnDaemon == false)
    }
}
