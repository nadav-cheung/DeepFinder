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

    /// Retrieve the API key. Checks Keychain first (secure storage), falls back
    /// to config dict (legacy/plaintext). Returns empty string if neither has a key.
    static func getAPIKey(config: [String: String], keychainStore: KeychainStore = KeychainStore()) -> String {
        if let keychainValue = keychainStore.load(key: "ai.apiKey"), !keychainValue.isEmpty {
            return keychainValue
        }
        return config["ai.apiKey"] ?? ""
    }

    /// Save the API key to Keychain (secure storage).
    static func saveAPIKey(_ value: String, keychainStore: KeychainStore = KeychainStore()) throws {
        try keychainStore.save(key: "ai.apiKey", value: value)
    }

    /// Generate a JSON sample showing what data would be sent to AI providers.
    /// Used by `deepfinder config get ai.data_preview` (REQ-3.0-02/15).
    static func dataPreview() -> String {
        let sample = FileMetadataSummary(
            name: "example.pdf",
            path: "~/Documents/example.pdf",
            size: 1_048_576,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extension: "pdf",
            localTags: ["document", "report"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sample) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
