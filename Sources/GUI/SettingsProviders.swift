import ServiceManagement
import SwiftUI

// MARK: - LaunchAtLoginProvider

/// Protocol abstracting launch-at-login for testability.
///
/// In production, ``SystemLaunchAtLoginProvider`` wraps `SMAppService`.
/// In tests, a mock stores the enabled state in memory.
protocol LaunchAtLoginProvider: Sendable {
    func isEnabled() async -> Bool
    func setEnabled(_ enabled: Bool) async -> Bool
}

/// Production implementation using `SMAppService` (macOS 13+).
struct SystemLaunchAtLoginProvider: LaunchAtLoginProvider {
    func isEnabled() async -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        do {
            if enabled {
                try await SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - SettingsConfigProvider

/// Protocol abstracting config access for the Settings view.
///
/// In production, this is backed by IPC calls to the daemon's ConfigStore.
/// In tests, this is replaced by a mock that stores state in memory.
protocol SettingsConfigProvider: Sendable {
    func getExcludedPaths() async -> [String]
    func addExcludedPath(_ path: String) async
    func removeExcludedPath(_ path: String) async
    func getIndexStats() async -> SettingsIndexStats
    func triggerRebuildIndex() async
}

// MARK: - SettingsAIProvider

/// Protocol abstracting AI config access for the Settings AI tab.
///
/// Decouples the view model from SecretsStore and ConfigStore so AI settings
/// can be tested without real file storage or IPC. In production, the implementation
/// reads/writes through IPC configSet/configGet and SecretsStore for API keys.
protocol SettingsAIProvider: Sendable {
    /// Whether AI assist is enabled.
    func isEnabled() async -> Bool
    /// Set AI assist enabled state.
    func setEnabled(_ enabled: Bool) async
    /// The selected AI model name ("off", "deepseek", "qwen").
    func modelName() async -> String
    /// Set the selected AI model.
    func setModel(_ model: String) async
    /// Retrieve the stored API key (from secrets file).
    func getAPIKey() async -> String
    /// Store the API key (to secrets file).
    func setAPIKey(_ key: String) async throws
    /// Whether metadata is sent to cloud providers.
    func sendMetadata() async -> Bool
    /// Set whether metadata is sent to cloud providers.
    func setSendMetadata(_ enabled: Bool) async
    /// Whether path anonymization is active.
    func pathAnonymization() async -> Bool
    /// Set path anonymization.
    func setPathAnonymization(_ enabled: Bool) async
    /// Whether local vision analysis is enabled.
    func localVision() async -> Bool
    /// Set local vision analysis.
    func setLocalVision(_ enabled: Bool) async
    /// Generate a JSON preview of data sent to AI providers.
    func dataPreview() async -> String
}

// MARK: - SettingsIndexStats

/// Index statistics displayed in the Settings Index tab.
struct SettingsIndexStats: Sendable, Equatable {
    let state: String
    let filesIndexed: Int
    let lastScanDate: Date?
}

// MARK: - SettingsTab

/// Tabs in the Settings window.
enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case index
    case ai
    case about
}

// MARK: - AIModelOption

/// Options for the AI model picker in Settings.
enum AIModelOption: String, CaseIterable, Sendable {
    case off
    case deepseek
    case qwen

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        }
    }
}
