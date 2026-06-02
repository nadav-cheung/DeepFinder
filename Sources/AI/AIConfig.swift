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
    case cloudFallback
    case embeddingModel
    case cacheTTL
    case customEndpoint
    case customModelName
    case customAPIKey
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
        "ai.cloudFallback": "true",
        "ai.embeddingModel": "nlcontextual",
        "ai.cacheTTL": "300",
        "ai.customEndpoint": "",
        "ai.customModelName": "",
        "ai.customAPIKey": "",
    ]

    /// Check whether AI is enabled in the given config dictionary.
    static func isEnabled(config: [String: String]) -> Bool {
        config["ai.enabled"] == "true"
    }

    /// Get the configured model name, or "off" if not set.
    static func modelName(config: [String: String]) -> String {
        config["ai.model"] ?? "off"
    }

    /// Retrieve the API key. Checks secrets file first, falls back to config dict
    /// (legacy/plaintext). Returns empty string if neither has a key.
    ///
    /// When a secrets file value is found, any stale plaintext entry in the config
    /// dictionary is cleaned up by calling the removal callback. The caller is
    /// responsible for persisting the updated config.
    static func getAPIKey(
        config: [String: String],
        secretsStore: SecretsStore = SecretsStore(),
        onPlaintextCleanup: ((String) -> Void)? = nil
    ) -> String {
        if let secretsValue = secretsStore.load(key: "ai.apiKey"), !secretsValue.isEmpty {
            // Clean up any stale plaintext copy from config
            if config["ai.apiKey"] != nil {
                onPlaintextCleanup?("ai.apiKey")
            }
            return secretsValue
        }
        return config["ai.apiKey"] ?? ""
    }

    /// Save the API key to secrets file and remove any plaintext copy from the
    /// config dictionary via the removal callback.
    static func saveAPIKey(
        _ value: String,
        secretsStore: SecretsStore = SecretsStore(),
        onPlaintextCleanup: ((String) -> Void)? = nil
    ) throws {
        try secretsStore.save(key: "ai.apiKey", value: value)
        // Remove any stale plaintext copy
        onPlaintextCleanup?("ai.apiKey")
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

    /// Get the configured embedding model name, or "nlcontextual" if not set.
    static func embeddingModelName(config: [String: String]) -> String {
        config["ai.embeddingModel"] ?? "nlcontextual"
    }

    /// Get the AI cache TTL in seconds, clamped to [60, 3600]. Default: 300.
    static func cacheTTL(config: [String: String]) -> Int {
        let raw = Int(config["ai.cacheTTL"] ?? "300") ?? 300
        return min(3600, max(60, raw))
    }

    /// Check whether cloud fallback is enabled. Defaults to true.
    static func cloudFallbackEnabled(config: [String: String]) -> Bool {
        config["ai.cloudFallback"] != "false"
    }

    /// Get the custom cloud endpoint URL, or empty string if not configured.
    static func customEndpoint(config: [String: String]) -> String {
        config["ai.customEndpoint"] ?? ""
    }

    /// Get the custom model name override, or empty string if not configured.
    static func customModelName(config: [String: String]) -> String {
        config["ai.customModelName"] ?? ""
    }

    /// Get the custom API key, or empty string if not configured.
    static func customAPIKey(config: [String: String]) -> String {
        config["ai.customAPIKey"] ?? ""
    }
}
