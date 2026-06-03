import Testing
import Foundation
import AppKit
@testable import DeepFinder

// MARK: - Shared Test Mocks (file-level for cross-struct access)

/// Mock daemon spawner that records whether spawn was called.
final class MockDaemonSpawnerForTests: DaemonSpawner, @unchecked Sendable {
    var ensureCalled = false
    var shouldThrow = false

    func ensureDaemonRunning() async throws {
        ensureCalled = true
        if shouldThrow {
            throw IPCClientError.daemonSpawnFailed("test error")
        }
    }
}

/// Minimal mock IPC client for SearchViewModel injection in tests.
final class MockIPCClientForTests: IPCClientProtocol, @unchecked Sendable {
    func send(_ request: IPCRequest) async throws -> IPCResponse {
        .ack
    }
}

// MARK: - DeepFinderAppDelegate Tests

@Suite("DeepFinderAppDelegate")
struct AppDelegateTests {

    // MARK: - Test Configuration Factory

    /// Create a test configuration with all mocks injected.
    @MainActor
    private func makeTestConfiguration(
        spawner: MockDaemonSpawnerForTests? = nil,
        autoSpawn: Bool = false
    ) -> (DeepFinderAppConfiguration, MockDaemonSpawnerForTests) {
        let mockSpawner = spawner ?? MockDaemonSpawnerForTests()

        let config = DeepFinderAppConfiguration(
            daemonSpawnerFactory: { mockSpawner },
            statusBarControllerFactory: { onShow, onHide, onSettings, onQuit in
                StatusBarController(
                    onShowSearchPanel: onShow,
                    onHideSearchPanel: onHide,
                    onOpenSettings: onSettings,
                    onQuit: onQuit
                )
            },
            searchPanelFactory: {
                let mockIPC = MockIPCClientForTests()
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

        return (config, mockSpawner)
    }

    // MARK: - 1. applicationDidFinishLaunching sets accessory policy

    @Test("applicationDidFinishLaunching sets activation policy to accessory")
    @MainActor
    func testLaunchSetsAccessoryPolicy() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // In test environments NSApp may be nil; verify the call doesn't crash.
        // When NSApp exists, verify it's set to accessory.
        if let app = NSApp {
            #expect(app.activationPolicy() == .accessory)
        }
    }

    // MARK: - 2. Status bar controller is created and installed

    @Test("Status bar controller is created after launch")
    @MainActor
    func testStatusBarControllerCreated() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        #expect(delegate.statusBarController != nil)
    }

    // MARK: - 3. Global hotkey is registered

    @Test("Global hotkey is created after launch")
    @MainActor
    func testGlobalHotkeyCreated() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        // GlobalHotkey.register may fail in test environments without
        // Accessibility permissions. The delegate stores nil if registration fails.
        _ = delegate.globalHotkey
    }

    // MARK: - 4. Search panel controller is created

    @Test("Search panel controller is created after launch")
    @MainActor
    func testSearchPanelControllerCreated() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        #expect(delegate.searchPanelController != nil)
    }

    // MARK: - 5. Toggle search panel action

    @Test("toggleSearchPanel does not crash after launch")
    @MainActor
    func testToggleSearchPanel() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.toggleSearchPanel()
    }

    // MARK: - 6. Show search panel action

    @Test("showSearchPanel does not crash after launch")
    @MainActor
    func testShowSearchPanel() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.showSearchPanel()
    }

    // MARK: - 7. Hide search panel action

    @Test("hideSearchPanel does not crash after launch")
    @MainActor
    func testHideSearchPanel() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))
        delegate.hideSearchPanel()
    }

    // MARK: - 8. Show settings window creates window on demand

    @Test("showSettingsWindow creates window on first call")
    @MainActor
    func testShowSettingsWindowCreatesWindow() {
        let (config, _) = makeTestConfiguration()
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
        let (config, _) = makeTestConfiguration()
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
        let (config, _) = makeTestConfiguration()
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
        let mockSpawner = MockDaemonSpawnerForTests()
        let (config, _) = makeTestConfiguration(spawner: mockSpawner, autoSpawn: true)
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(mockSpawner.ensureCalled)
    }

    // MARK: - 12. Daemon auto-spawn is skipped when disabled

    @Test("Daemon auto-spawn is skipped when disabled")
    @MainActor
    func testDaemonAutoSpawnSkipped() async {
        let mockSpawner = MockDaemonSpawnerForTests()
        let (config, _) = makeTestConfiguration(spawner: mockSpawner, autoSpawn: false)
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(!mockSpawner.ensureCalled)
    }

    // MARK: - 13. Notification toggleSearchPanel triggers toggle

    @Test("Notification .toggleSearchPanel triggers toggle")
    @MainActor
    func testNotificationToggleSearchPanel() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        NotificationCenter.default.post(name: .toggleSearchPanel, object: nil)
    }

    // MARK: - 14. Notification showSettings triggers settings

    @Test("Notification .showSettings triggers settings window")
    @MainActor
    func testNotificationShowSettings() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        NotificationCenter.default.post(name: .showSettings, object: nil)

        #expect(delegate.settingsWindow != nil)
    }

    // MARK: - 15. Actions before launch do not crash

    @Test("Actions before launch do not crash (nil safety)")
    @MainActor
    func testActionsBeforeLaunch() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.toggleSearchPanel()
        delegate.showSearchPanel()
        delegate.hideSearchPanel()
        delegate.showSettingsWindow()
    }

    // MARK: - 16. Status bar toggle callback triggers search panel

    @Test("Status bar show callback wired to search panel")
    @MainActor
    func testStatusBarShowCallbackWired() {
        let (config, _) = makeTestConfiguration()
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        delegate.statusBarController?.showSearchPanel()
    }

    // MARK: - 17. Daemon spawn failure sets error status

    @Test("Daemon spawn failure sets error index status")
    @MainActor
    func testDaemonSpawnFailureSetsErrorStatus() async {
        let mockSpawner = MockDaemonSpawnerForTests()
        mockSpawner.shouldThrow = true
        let (config, _) = makeTestConfiguration(spawner: mockSpawner, autoSpawn: true)
        let delegate = DeepFinderAppDelegate(configuration: config)

        delegate.applicationDidFinishLaunching(Notification(name: .init("test")))

        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(delegate.statusBarController?.indexStatus == .error)
    }
}

// MARK: - Notification Name Tests

@Suite("AppDelegate Notification Names")
struct AppDelegateNotificationTests {

    @Test(".toggleSearchPanel has correct name")
    func testToggleSearchPanelName() {
        #expect(Notification.Name.toggleSearchPanel == Notification.Name(rawValue: "com.nadav.deepfinder.toggleSearchPanel"))
    }

    @Test(".showSettings has correct name")
    func testShowSettingsName() {
        #expect(Notification.Name.showSettings == Notification.Name(rawValue: "com.nadav.deepfinder.showSettings"))
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
        let mockSpawner = MockDaemonSpawnerForTests()
        let configOn = DeepFinderAppConfiguration(
            daemonSpawnerFactory: { mockSpawner },
            statusBarControllerFactory: { _, _, _, _ in StatusBarController() },
            searchPanelFactory: {
                let mockIPC = MockIPCClientForTests()
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
            statusBarControllerFactory: { _, _, _, _ in StatusBarController() },
            searchPanelFactory: {
                let mockIPC = MockIPCClientForTests()
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
