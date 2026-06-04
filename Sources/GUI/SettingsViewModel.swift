import OSLog
import SwiftUI

// MARK: - SettingsViewModel

/// View model driving the Settings view.
///
/// Bridges the SwiftUI view layer with the async config provider (IPC in production, mock in tests).
/// All mutations go through the config provider so changes are persisted to the daemon.
@MainActor
@Observable
final class SettingsViewModel {

    // MARK: - Logging

    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "settings")

    // MARK: - State

    /// Currently selected tab.
    var selectedTab: SettingsTab = .general

    /// List of paths excluded from indexing.
    var excludedPaths: [String] = []

    /// Index statistics from the daemon.
    var indexStats: SettingsIndexStats?

    /// Text field input for adding a new excluded path.
    var newPathText: String = ""

    /// The app version string.
    let version: String

    // MARK: - AI State

    /// Whether AI assist is enabled.
    var aiEnabled: Bool = false

    /// Selected AI model ("off", "deepseek", "qwen").
    var aiModel: AIModelOption = .off

    /// The API key text (masked in UI, stored in secrets file).
    var aiAPIKeyText: String = ""

    /// Whether metadata is sent to cloud AI providers.
    var aiSendMetadata: Bool = false

    /// Whether path anonymization is active.
    var aiPathAnonymization: Bool = true

    /// Whether local vision analysis is enabled.
    var aiLocalVision: Bool = true

    /// Preview data output from AIConfig.dataPreview().
    var aiPreviewData: String = ""

    /// Whether the preview sheet is visible.
    var aiPreviewVisible: Bool = false

    /// Whether a rebuild index operation is in progress.
    var isRebuilding: Bool = false

    /// The current global hotkey display string.
    var hotkeyDisplay: String = "⌃⌘K"

    // MARK: - Auto-Launch State

    /// Whether auto-launch at login is enabled.
    var autoLaunchEnabled: Bool = false

    /// Alert message shown when auto-launch registration fails.
    var autoLaunchError: String?

    // MARK: - Dependencies

    private let configProvider: any SettingsConfigProvider
    private let aiProvider: (any SettingsAIProvider)?
    private let launchProvider: any LaunchAtLoginProvider

    // MARK: - Init

    init(
        configProvider: any SettingsConfigProvider,
        aiProvider: (any SettingsAIProvider)? = nil,
        launchProvider: any LaunchAtLoginProvider = SystemLaunchAtLoginProvider()
    ) {
        self.configProvider = configProvider
        self.aiProvider = aiProvider
        self.launchProvider = launchProvider
        self.version = Product.version
    }

    // MARK: - Config Loading

    /// Load excluded paths and index stats from the config provider.
    func loadConfig() async {
        excludedPaths = await configProvider.getExcludedPaths()
    }

    /// Load index statistics from the daemon.
    func loadIndexStats() async {
        indexStats = await configProvider.getIndexStats()
    }

    /// Load AI configuration from the AI provider.
    func loadAIConfig() async {
        guard let aiProvider else { return }
        aiEnabled = await aiProvider.isEnabled()
        let model = await aiProvider.modelName()
        aiModel = AIModelOption(rawValue: model) ?? .off
        aiAPIKeyText = await aiProvider.getAPIKey()
        aiSendMetadata = await aiProvider.sendMetadata()
        aiPathAnonymization = await aiProvider.pathAnonymization()
        aiLocalVision = await aiProvider.localVision()
    }

    /// Load auto-launch state from the launch provider.
    func loadAutoLaunchConfig() async {
        autoLaunchEnabled = await launchProvider.isEnabled()
    }

    // MARK: - Path Mutations

    /// Add a path to the exclusion list and persist via the provider.
    func addPath(_ path: String) async {
        await configProvider.addExcludedPath(path)
        excludedPaths = await configProvider.getExcludedPaths()
    }

    /// Remove a path from the exclusion list and persist via the provider.
    func removePath(_ path: String) async {
        await configProvider.removeExcludedPath(path)
        excludedPaths = await configProvider.getExcludedPaths()
    }

    // MARK: - Index Rebuild

    /// Trigger an index rebuild via the config provider.
    func rebuildIndex() async {
        isRebuilding = true
        await configProvider.triggerRebuildIndex()
        isRebuilding = false
        await loadIndexStats()
    }

    // MARK: - AI Mutations

    /// Persist AI enabled state.
    func setAIEnabled(_ enabled: Bool) async {
        aiEnabled = enabled
        await aiProvider?.setEnabled(enabled)
    }

    /// Persist AI model selection.
    func setAIModel(_ model: AIModelOption) async {
        aiModel = model
        await aiProvider?.setModel(model.rawValue)
    }

    /// Persist API key to secrets file. Errors are logged but not propagated to avoid
    /// disrupting the UI binding flow (SecureField calls this on every keystroke).
    func setAIKey(_ key: String) async {
        aiAPIKeyText = key
        do { try await aiProvider?.setAPIKey(key) }
        catch { logger.warning("Failed to save AI API key: \(error.localizedDescription, privacy: .public)") }
    }

    /// Persist send metadata toggle.
    func setAISendMetadata(_ enabled: Bool) async {
        aiSendMetadata = enabled
        await aiProvider?.setSendMetadata(enabled)
    }

    /// Persist path anonymization toggle.
    func setAIPathAnonymization(_ enabled: Bool) async {
        aiPathAnonymization = enabled
        await aiProvider?.setPathAnonymization(enabled)
    }

    /// Persist local vision toggle.
    func setAILocalVision(_ enabled: Bool) async {
        aiLocalVision = enabled
        await aiProvider?.setLocalVision(enabled)
    }

    /// Load the data preview from the AI provider.
    func loadAIPreview() async {
        aiPreviewData = await aiProvider?.dataPreview() ?? AIConfig.dataPreview()
    }

    // MARK: - Hotkey

    /// Reset the global hotkey display to the default.
    func resetHotkeyDisplay() {
        hotkeyDisplay = "⌃⌘K"
    }

    // MARK: - Auto-Launch

    /// Toggle auto-launch at login. Returns false and sets `autoLaunchError` on failure.
    func setAutoLaunch(_ enabled: Bool) async {
        autoLaunchError = nil
        let success = await launchProvider.setEnabled(enabled)
        if success {
            autoLaunchEnabled = enabled
        } else {
            autoLaunchError = "Failed to \(enabled ? "enable" : "disable") login item. Check System Settings > Login Items."
        }
    }
}
