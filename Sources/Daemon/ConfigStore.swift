/// Persistent daemon configuration stored as JSON at `~/.deep-finder/settings.json`.
///
/// Provides atomic reads and writes (temp-file + rename) so the config file never
/// becomes corrupted by a partial write. Holds indexing exclusions, batch sizes,
/// and result limits that the daemon reads at startup and the CLI can modify at runtime.
import Foundation

// MARK: - DaemonConfig

/// Persistent daemon configuration.
///
/// Stored as JSON at `~/.deep-finder/settings.json` with file permissions 600.
/// When the file is missing or corrupted, defaults are used.
struct DaemonConfig: Codable, Sendable, Equatable {

    /// Paths excluded from indexing.
    var excludedPaths: [String]

    /// Volume mount paths excluded from indexing (e.g. "/Volumes/Time Machine").
    /// Local volumes are always indexed. External and network volumes are indexed
    /// by default unless listed here.
    var excludedVolumes: [String]

    /// Number of records to batch-write to SQLite at once.
    var indexBatchSize: Int

    /// Maximum number of results returned per query.
    var maxResults: Int

    /// Schema version for forward-compatible migrations.
    var configVersion: Int

    /// Default configuration values used when the config file is missing or corrupted.
    static let defaults = DaemonConfig(
        excludedPaths: Constants.Scan.alwaysExcludedPrefixes,
        excludedVolumes: [],
        indexBatchSize: Constants.Daemon.indexBatchSize,
        maxResults: Constants.Daemon.maxResults,
        configVersion: 1
    )
}

// MARK: - ConfigStoreError

/// Errors thrown by ``ConfigStore`` during validation.
enum ConfigStoreError: Error, CustomStringConvertible {
    case invalidValue(key: String, reason: String)

    var description: String {
        switch self {
        case .invalidValue(let key, let reason):
            return "Invalid value for '\(key)': \(reason)"
        }
    }
}

// MARK: - ConfigStore

/// Persistent, atomic configuration store for the daemon.
///
/// All access is serialized through actor isolation. Writes use a temp-file +
/// rename strategy to prevent partial writes from corrupting the config file.
actor ConfigStore {

    /// Path to the JSON config file on disk.
    private let configPath: String

    /// In-memory copy of the current config.
    private var config: DaemonConfig

    // MARK: - Init

    /// Create a ConfigStore backed by the given file path.
    ///
    /// If the file exists and is valid JSON, its values are loaded.
    /// If the file is missing or corrupted, defaults are used.
    init(configPath: String) {
        self.configPath = configPath
        self.config = Self.loadFromDisk(path: configPath) ?? .defaults
    }

    // MARK: - Public API

    /// Return the full current configuration.
    func get() -> DaemonConfig {
        config
    }

    /// Return a single config value by key name, as a String.
    /// Returns nil for unknown keys.
    func get(key: String) -> String? {
        switch key {
        case "excludedPaths":
            return (try? JSONEncoder().encode(config.excludedPaths)).flatMap { String(data: $0, encoding: .utf8) }
        case "excludedVolumes":
            return (try? JSONEncoder().encode(config.excludedVolumes)).flatMap { String(data: $0, encoding: .utf8) }
        case "indexBatchSize":
            return String(config.indexBatchSize)
        case "maxResults":
            return String(config.maxResults)
        case "configVersion":
            return String(config.configVersion)
        default:
            return nil
        }
    }

    /// Set a single config key and persist atomically.
    ///
    /// - Throws: `ConfigStoreError.invalidValue` if the value cannot be parsed
    ///   into the expected type for the given key.
    func set(key: String, value: String) throws {
        switch key {
        case "excludedPaths":
            guard let data = value.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a JSON array of strings")
            }
            config.excludedPaths = paths
        case "excludedVolumes":
            guard let data = value.data(using: .utf8),
                  let volumes = try? JSONDecoder().decode([String].self, from: data) else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a JSON array of strings")
            }
            config.excludedVolumes = volumes
        case "indexBatchSize":
            guard let v = Int(value), v > 0 else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a positive integer")
            }
            config.indexBatchSize = v
        case "maxResults":
            guard let v = Int(value), v > 0 else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a positive integer")
            }
            config.maxResults = v
        case "configVersion":
            guard let v = Int(value), v > 0 else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a positive integer")
            }
            config.configVersion = v
        default:
            throw ConfigStoreError.invalidValue(key: key, reason: "Unknown configuration key")
        }
        try persist()
    }

    /// Atomically update the full config via a transform closure.
    ///
    /// The closure receives the current config and must return the new config.
    /// The result is validated and persisted atomically.
    func update(_ transform: (DaemonConfig) -> DaemonConfig) throws {
        let updated = transform(config)
        // Basic validation
        guard updated.indexBatchSize > 0 else {
            throw ConfigStoreError.invalidValue(key: "indexBatchSize", reason: "Must be positive")
        }
        guard updated.maxResults > 0 else {
            throw ConfigStoreError.invalidValue(key: "maxResults", reason: "Must be positive")
        }
        config = updated
        try persist()
    }

    // MARK: - Persistence

    /// Write config to disk atomically (temp file + rename) with permissions 600.
    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        let url = URL(fileURLWithPath: configPath)
        let dir = url.deletingLastPathComponent()

        // Ensure parent directory exists
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write to temp file in same directory (same filesystem for atomic rename)
        let tmpURL = dir.appendingPathComponent(".config.json.tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)

        // Set permissions before rename
        try FileManager.default.setAttributes([.posixPermissions: Product.privateFilePermissions], ofItemAtPath: tmpURL.path)

        // Atomic rename: remove existing file first (moveItem refuses to overwrite)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }

    // MARK: - Load

    /// Attempt to load config from disk. Returns nil on any failure (missing, corrupt).
    private static func loadFromDisk(path: String) -> DaemonConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(DaemonConfig.self, from: data)
    }
}
