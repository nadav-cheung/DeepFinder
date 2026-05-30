import Foundation

// MARK: - AIConfigKey

/// Configuration keys for AI features.
///
/// These map to the CLI config system:
///   `deepfinder config set ai.<key> <value>`
///   `deepfinder config get ai.<key>`
enum AIConfigKey: String, CaseIterable {
    case enabled
    case model
    case sendMetadata
    case pathAnonymization
    case localVision
    case apiKey
}

// MARK: - AIConfig

/// Static helper for reading AI-related configuration values.
///
/// AI config values are stored as strings in the existing ConfigStore
/// under the "ai.<key>" namespace. This struct provides typed accessors
/// and documented defaults.
struct AIConfig: Sendable {
    /// Default values for all AI config keys.
    ///
    /// All AI features are OFF by default -- the user must explicitly
    /// opt in via `deepfinder config set ai.enabled true`.
    static let defaults: [String: String] = [
        "ai.enabled": "false",
        "ai.model": "off",
        "ai.sendMetadata": "false",
        "ai.pathAnonymization": "true",
        "ai.localVision": "true",
        "ai.apiKey": "",
    ]

    /// Check whether AI is enabled in the given config dictionary.
    static func isEnabled(config: [String: String]) -> Bool {
        config["ai.enabled"] == "true"
    }

    /// Get the configured model name, or "off" if not set.
    static func modelName(config: [String: String]) -> String {
        config["ai.model"] ?? "off"
    }
}
