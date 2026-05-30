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
///
/// **Privacy-first defaults**: All cloud-dependent AI features are OFF by default.
/// The user must explicitly opt in:
/// ```
/// deepfinder config set ai.enabled true
/// deepfinder config set ai.model deepseek
/// deepfinder config set ai.apiKey sk-...
/// ```
/// Local-only features (vision, speech) default to enabled since they never leave the device.
struct AIConfig: Sendable {
    /// Default values for all AI config keys.
    ///
    /// - `ai.enabled`: `"false"` -- master switch, must be explicitly enabled
    /// - `ai.model`: `"off"` -- no provider configured until user sets one
    /// - `ai.sendMetadata`: `"false"` -- metadata not sent to cloud unless opted in
    /// - `ai.pathAnonymization`: `"true"` -- paths anonymized by default for privacy
    /// - `ai.localVision`: `"true"` -- on-device vision analysis enabled (no network)
    /// - `ai.apiKey`: `""` -- empty until user provides one
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
