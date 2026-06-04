import AppKit
import Foundation
import OSLog

// MARK: - Notification Names

/// Notification names for inter-component communication within the GUI.
///
/// These allow decoupled components (status bar, search panel, settings, hotkey)
/// to signal each other without direct references.
extension Notification.Name {
    /// Toggle the search panel visibility.
    static let toggleSearchPanel = Notification.Name("\(Product.identifier).toggleSearchPanel")
    /// Show the settings window.
    static let showSettings = Notification.Name("\(Product.identifier).showSettings")
}

// MARK: - DaemonSpawner

/// Protocol abstracting daemon auto-spawn for testability.
///
/// Production uses `IPCClient.ensureDaemonRunning()`. Tests inject a mock
/// to verify spawn behavior without starting a real process.
public protocol DaemonSpawner: Sendable {
    func ensureDaemonRunning() async throws
}

// MARK: - DeepFinderAppConfiguration

/// Configuration struct providing all injectable components for `DeepFinderAppDelegate`.
///
/// Enables test-time injection of mock status bar, hotkey, search panel, and daemon
/// spawner. Production creates a `DeepFinderAppConfiguration` with real components.
public struct DeepFinderAppConfiguration: Sendable {
    /// Key combination for the global hotkey. Default: Ctrl+Cmd+K.
    var hotkeyCombination: KeyCombination = GlobalHotkey.defaultKeyCombination

    /// Factory closure that creates a `DaemonSpawner`. Called once during launch.
    var daemonSpawnerFactory: @Sendable () -> any DaemonSpawner

    /// Factory closure that creates a `StatusBarController` with wired callbacks.
    /// Parameters: show, hide, settings, quit closures.
    var statusBarControllerFactory: @MainActor @Sendable (
        _ onShow: @escaping () -> Void,
        _ onHide: @escaping () -> Void,
        _ onSettings: @escaping () -> Void,
        _ onQuit: @escaping () -> Void
    ) -> StatusBarController

    /// Factory closure that creates a `SearchPanelHostingController`.
    var searchPanelFactory: @MainActor @Sendable () -> SearchPanelHostingController

    /// Factory closure that creates a settings `NSWindow`.
    var settingsWindowFactory: @MainActor @Sendable () -> NSWindow

    /// Whether to auto-spawn the daemon on launch. Default: true.
    var autoSpawnDaemon: Bool = true
}

// MARK: - DeepFinderAppDelegate

/// Application delegate for the DeepFinder GUI.
///
/// Manages the app lifecycle: sets activation policy to `.accessory` (LSUIElement — no
/// Dock icon), installs the status bar controller, registers the global hotkey,
/// and auto-spawns the daemon on first launch.
///
/// This is **not** an `@main` entry point. The GUI compiles as part of the library
/// target. An external app target or Xcode project creates an `NSApplication` and
/// sets this as the delegate programmatically:
///
/// ```swift
/// let app = NSApplication.shared
/// let config = DeepFinderAppConfiguration.production()
/// app.delegate = DeepFinderAppDelegate(configuration: config)
/// app.run()
/// ```
///
/// ## Inter-component communication
///
/// Components communicate via `NotificationCenter` using typed notification names:
/// - `.toggleSearchPanel` — posted by the global hotkey handler.
/// - `.showSettings` — posted when settings should appear.
///
/// The AppDelegate subscribes to these and dispatches to the appropriate controller.
@MainActor
public final class DeepFinderAppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "app-delegate")

    /// The configuration providing all injectable components.
    private let configuration: DeepFinderAppConfiguration

    /// Status bar controller managing the menu bar icon.
    private(set) var statusBarController: StatusBarController?

    /// Global hotkey (Ctrl+Cmd+K) registration.
    private(set) var globalHotkey: GlobalHotkey?

    /// Search panel hosting controller.
    private(set) var searchPanelController: SearchPanelHostingController?

    /// Settings window (retained to avoid premature deallocation).
    private(set) var settingsWindow: NSWindow?

    /// Daemon spawner for auto-start on launch.
    private var daemonSpawner: (any DaemonSpawner)?

    /// Index health monitor for tracking daemon index status.
    private var indexHealthMonitor: IndexHealthMonitor?

    // MARK: - Init

    /// Create the app delegate with the given configuration.
    ///
    /// - Parameter configuration: Injected components and factories.
    public init(configuration: DeepFinderAppConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement: no Dock icon, no main menu.
        NSApp?.setActivationPolicy(.accessory)

        // Belt-and-suspenders defence against automatic termination. The primary
        // mechanism is `NSApplicationSupportsAutomaticTermination = NO` in
        // `App/Info.plist`; this ProcessInfo call is a runtime backup.
        ProcessInfo.processInfo.disableAutomaticTermination("DeepFinder menu bar app running")
        logger.notice("applicationDidFinishLaunching — automatic termination disabled")

        // Subscribe to inter-component notifications.
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleToggleSearchPanel),
            name: .toggleSearchPanel,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )

        // Create search panel controller.
        searchPanelController = configuration.searchPanelFactory()

        // Create index health monitor and wire to search panel.
        let ipcClientForMonitor = IPCClient(socketPath: Product.socketPath)
        let monitor = IndexHealthMonitor(ipcClient: ipcClientForMonitor)
        self.indexHealthMonitor = monitor
        monitor.startPolling()
        searchPanelController?.setIndexHealthMonitor(monitor)

        // Create status bar controller with wired actions.
        statusBarController = configuration.statusBarControllerFactory(
            { [weak self] in self?.showSearchPanel() },
            { [weak self] in self?.hideSearchPanel() },
            { [weak self] in self?.showSettingsWindow() },
            { [weak self] in self?.requestQuit() }
        )
        statusBarController?.install()

        // Register global hotkey.
        let hotkey = GlobalHotkey(keyCombination: configuration.hotkeyCombination)
        let registered = hotkey.register { [weak self] in
            Task { @MainActor in self?.toggleSearchPanel() }
        }
        self.globalHotkey = registered ? hotkey : nil
        logger.info("Global hotkey registered: \(registered)")

        // Auto-spawn daemon.
        if configuration.autoSpawnDaemon {
            daemonSpawner = configuration.daemonSpawnerFactory()
            Task {
                do {
                    try await daemonSpawner?.ensureDaemonRunning()
                    statusBarController?.updateIndexStatus(.live)
                } catch {
                    statusBarController?.updateIndexStatus(.error)
                    logger.error("Daemon spawn failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // LSUIElement menu bar app — closing the last window should NOT quit the app.
        // The status bar icon stays alive for future interactions.
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }

    public func applicationWillTerminate(_ notification: Notification) {
        logger.info("applicationWillTerminate — cleaning up")

        // Stop index health monitoring.
        indexHealthMonitor?.stopPolling()
        indexHealthMonitor = nil

        // Unregister global hotkey.
        globalHotkey?.unregister()
        globalHotkey = nil

        // Remove status bar item.
        statusBarController?.remove()
        statusBarController = nil

        // Clean up search panel.
        searchPanelController?.hide()
        searchPanelController = nil

        // Clean up settings window.
        settingsWindow?.close()
        settingsWindow = nil

        // Remove notification observers.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions

    /// Toggle search panel visibility.
    func toggleSearchPanel() {
        NSApp?.activate(ignoringOtherApps: true)
        searchPanelController?.toggle()
    }

    /// Show the search panel.
    func showSearchPanel() {
        NSApp?.activate(ignoringOtherApps: true)
        searchPanelController?.show()
    }

    /// Hide the search panel.
    func hideSearchPanel() {
        searchPanelController?.hide()
    }

    /// Show the settings window (creates on first call, reuses after).
    func showSettingsWindow() {
        NSApp?.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            settingsWindow = configuration.settingsWindowFactory()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Called when the user clicks "Quit" from the status bar menu.
    func requestQuit() {
        logger.info("requestQuit — user requested termination")
        NSApp?.terminate(nil)
    }

    // MARK: - Notification Handlers

    @objc private func handleToggleSearchPanel(_ notification: Notification) {
        toggleSearchPanel()
    }

    @objc private func handleShowSettings(_ notification: Notification) {
        showSettingsWindow()
    }
}

// MARK: - DeepFinderAppConfiguration Production Factory

extension DeepFinderAppConfiguration {

    /// Create a production configuration with real components.
    ///
    /// Wires `StatusBarController` callbacks, `SearchPanelHostingController`,
    /// `GlobalHotkey`, and `IPCClient`-based daemon spawner.
    public static func production() -> DeepFinderAppConfiguration {
        DeepFinderAppConfiguration(
            daemonSpawnerFactory: {
                DaemonSpawnerViaIPCClient()
            },
            statusBarControllerFactory: { onShow, onHide, onSettings, onQuit in
                StatusBarController(
                    onShowSearchPanel: onShow,
                    onHideSearchPanel: onHide,
                    onOpenSettings: onSettings,
                    onQuit: onQuit
                )
            },
            searchPanelFactory: {
                let viewModel = SearchViewModel(
                    ipcClient: IPCClient(socketPath: Product.socketPath)
                )
                return SearchPanelHostingController(viewModel: viewModel)
            },
            settingsWindowFactory: {
                let ipcClient = IPCClient(socketPath: Product.socketPath)
                let configProvider = IPCSettingsConfigProvider(ipcClient: ipcClient)
                return SettingsWindow.createWindow(configProvider: configProvider)
            }
        )
    }
}

// MARK: - DaemonSpawnerViaIPCClient

/// Production `DaemonSpawner` that delegates to `IPCClient.ensureDaemonRunning()`.
private final class DaemonSpawnerViaIPCClient: DaemonSpawner {
    func ensureDaemonRunning() async throws {
        let client = IPCClient(socketPath: Product.socketPath)
        try await client.ensureDaemonRunning()
    }
}

// MARK: - IPCSettingsConfigProvider

/// Production `SettingsConfigProvider` backed by IPC calls to the daemon.
///
/// Translates `SettingsConfigProvider` method calls into `IPCRequest.configGet`/
/// `IPCRequest.configSet` messages and parses the daemon's responses.
private final class IPCSettingsConfigProvider: SettingsConfigProvider {
    private let ipcClient: IPCClient
    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "settings-ipc")

    init(ipcClient: IPCClient) {
        self.ipcClient = ipcClient
    }

    func getExcludedPaths() async -> [String] {
        do {
            let response = try await ipcClient.send(.configGet(key: "excludedPaths"))
            if case .results(let results, _) = response {
                return results.map { $0.record.originalName }
            }
        } catch {
            logger.warning("Failed to get excluded paths from daemon: \(error.localizedDescription, privacy: .public)")
        }
        return []
    }

    func addExcludedPath(_ path: String) async {
        do {
            _ = try await ipcClient.send(.configSet(key: "addExcludedPath", value: path))
        } catch {
            logger.warning("Failed to add excluded path '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeExcludedPath(_ path: String) async {
        do {
            _ = try await ipcClient.send(.configSet(key: "removeExcludedPath", value: path))
        } catch {
            logger.warning("Failed to remove excluded path '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    func getIndexStats() async -> SettingsIndexStats {
        do {
            let response = try await ipcClient.send(.indexStatus)
            if case .indexStatus(let s) = response {
                return SettingsIndexStats(
                    state: s.state,
                    filesIndexed: s.filesIndexed,
                    lastScanDate: s.lastScanDate
                )
            }
        } catch {
            logger.warning("Failed to get index stats from daemon: \(error.localizedDescription, privacy: .public)")
        }
        return SettingsIndexStats(state: "unknown", filesIndexed: 0, lastScanDate: nil)
    }

    func triggerRebuildIndex() async {
        do {
            _ = try await ipcClient.send(.configSet(key: "rebuildIndex", value: "true"))
        } catch {
            logger.warning("Failed to trigger index rebuild: \(error.localizedDescription, privacy: .public)")
        }
    }
}
