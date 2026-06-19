// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// Persistent daemon configuration stored as JSON at `~/.deep-finder/settings.json`.
///
/// Provides atomic reads and writes (temp-file + rename) so the config file never
/// becomes corrupted by a partial write. Holds indexing exclusions, batch sizes,
/// and result limits that the daemon reads at startup and the CLI can modify at runtime.
import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderFS
import DeepFinderPersist

// MARK: - DaemonConfig

/// Persistent daemon configuration.
///
/// Stored as JSON at `~/.deep-finder/settings.json` with file permissions 600.
/// When the file is missing or corrupted, defaults are used.
public struct DaemonConfig: Codable, Sendable, Equatable {

    /// Paths excluded from indexing (prefix match).
    public var excludedPaths: [String]

    /// Volume mount paths excluded from indexing (e.g. "/Volumes/Time Machine").
    public var excludedVolumes: [String]

    /// Directory basenames excluded from scanning (e.g. ".git", "node_modules").
    public var excludedNames: [String] = Constants.Scan.alwaysSkippedNames.sorted()

    /// Individual file basenames always skipped (e.g. ".DS_Store", "Thumbs.db").
    public var excludedFiles: [String] = Constants.Scan.alwaysSkippedFiles.sorted()

    /// File extensions always skipped (e.g. "o", "pyc", "class").
    public var excludedExtensions: [String] = Constants.Scan.alwaysSkippedExtensions.sorted()

    /// Maximum filename length for FullSubstringMap indexing (default: 24).
    /// Shorter = less memory. Names longer than this use TrigramIndex fallback.
    public var substringMaxLength: Int = Constants.Scan.defaultSubstringMaxLength

    /// Number of records to batch-write to SQLite at once.
    public var indexBatchSize: Int

    /// Maximum number of results returned per query.
    public var maxResults: Int

    /// Schema version for forward-compatible migrations.
    public var configVersion: Int

    /// Persisted REPL result-sort criterion (REQ-1.3-04). Optional so existing
    /// `settings.json` files written before this field existed still decode.
    /// `nil`/empty = daemon relevance order. Value is a `SortCriterion.persistenceKey`.
    public var sortPreference: String?

    /// Persisted REPL reverse-sort toggle. `nil`/`false` = ascending.
    public var sortReverse: Bool?

    /// Default configuration values used when the config file is missing or corrupted.
    public static let defaults = DaemonConfig(
        excludedPaths: Constants.Scan.alwaysExcludedPrefixes,
        excludedVolumes: [],
        excludedNames: Constants.Scan.alwaysSkippedNames.sorted(),
        excludedFiles: Constants.Scan.alwaysSkippedFiles.sorted(),
        excludedExtensions: Constants.Scan.alwaysSkippedExtensions.sorted(),
        substringMaxLength: Constants.Scan.defaultSubstringMaxLength,
        indexBatchSize: Constants.Daemon.indexBatchSize,
        maxResults: Constants.Daemon.maxResults,
        configVersion: 3
    )

    /// Serialize every field to its string form for the IPC `config_get` wire format.
    ///
    /// Single source of truth for the field→string mapping — used by both
    /// ``ConfigStore/get(key:)`` and the daemon's `configGetProvider`, so the set of
    /// keys and their serialization cannot drift between the two callers. Array fields
    /// are JSON-encoded (e.g. `["/a","/b"]`); scalar fields are plain integers.
    public func serializedDictionary() -> [String: String] {
        func jsonString<T: Encodable>(_ value: T) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let str = String(data: data, encoding: .utf8) else { return "[]" }
            return str
        }
        return [
            "excludedPaths": jsonString(excludedPaths),
            "excludedVolumes": jsonString(excludedVolumes),
            "excludedNames": jsonString(excludedNames),
            "excludedFiles": jsonString(excludedFiles),
            "excludedExtensions": jsonString(excludedExtensions),
            "substringMaxLength": String(substringMaxLength),
            "indexBatchSize": String(indexBatchSize),
            "maxResults": String(maxResults),
            "configVersion": String(configVersion),
            "sort": sortPreference ?? "",
            "sortReverse": (sortReverse ?? false) ? "true" : "false",
        ]
    }
}

// MARK: - ConfigStoreError

/// Errors thrown by ``ConfigStore`` during validation.
public enum ConfigStoreError: Error, CustomStringConvertible {
    case invalidValue(key: String, reason: String)

    public var description: String {
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
public actor ConfigStore {

    /// Path to the JSON config file on disk.
    private let configPath: String

    /// In-memory copy of the current config.
    private var config: DaemonConfig

    // MARK: - Init

    /// Create a ConfigStore backed by the given file path.
    ///
    /// If the file exists and is valid JSON, its values are loaded.
    /// If the file is missing or corrupted, defaults are used.
    public init(configPath: String) {
        self.configPath = configPath
        self.config = Self.loadFromDisk(path: configPath) ?? .defaults
    }

    // MARK: - Public API

    /// Return the full current configuration.
    public func get() -> DaemonConfig {
        config
    }

    /// Return a single config value by key name, as a String.
    /// Returns nil for unknown keys. Delegates to ``DaemonConfig/serializedDictionary()``
    /// so the key set and serialization are shared with the daemon's `configGetProvider`.
    public func get(key: String) -> String? {
        config.serializedDictionary()[key]
    }

    /// Set a single config key and persist atomically.
    ///
    /// - Throws: `ConfigStoreError.invalidValue` if the value cannot be parsed
    ///   into the expected type for the given key.
    public func set(key: String, value: String) throws {
        switch key {
        case "excludedPaths":
            guard let data = value.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a JSON array of strings")
            }
            config.excludedPaths = paths
        case "excludedNames":
            guard let data = value.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a JSON array of strings")
            }
            config.excludedNames = names
        case "excludedFiles":
            guard let data = value.data(using: .utf8),
                  let files = try? JSONDecoder().decode([String].self, from: data) else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a JSON array of strings")
            }
            config.excludedFiles = files
        case "excludedExtensions":
            guard let data = value.data(using: .utf8),
                  let exts = try? JSONDecoder().decode([String].self, from: data) else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a JSON array of strings")
            }
            config.excludedExtensions = exts
        case "substringMaxLength":
            guard let v = Int(value), v >= 0, v <= 64 else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected integer 0-64")
            }
            config.substringMaxLength = v
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
        case "sort":
            // Empty string clears the preference; otherwise validate against the
            // accepted criterion names (SortCriterion.persistenceKey values).
            if value.isEmpty {
                config.sortPreference = nil
            } else if SortCriterion.from(persistenceKey: value) != nil {
                config.sortPreference = value
            } else {
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected a sort criterion (relevance/name/date/size/natural) or empty")
            }
        case "sortReverse":
            switch value.lowercased() {
            case "true", "1":
                config.sortReverse = true
            case "false", "0":
                config.sortReverse = false
            default:
                throw ConfigStoreError.invalidValue(key: key, reason: "Expected true/false")
            }
        default:
            throw ConfigStoreError.invalidValue(key: key, reason: "Unknown configuration key")
        }
        try persist()
    }

    /// Atomically update the full config via a transform closure.
    ///
    /// The closure receives the current config and must return the new config.
    /// The result is validated and persisted atomically.
    public func update(_ transform: (DaemonConfig) -> DaemonConfig) throws {
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

        // Publish atomically. `replaceItem` swaps the files with no window in which the
        // destination is missing — if the swap fails the original config is left intact,
        // so a crash or error can never leave the config deleted (which the previous
        // remove-then-move sequence could). On the first write (no existing file) a
        // same-filesystem rename is itself atomic.
        if FileManager.default.fileExists(atPath: url.path) {
            var resultURL: NSURL?
            try FileManager.default.replaceItem(
                at: url,
                withItemAt: tmpURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: &resultURL
            )
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }

    // MARK: - Load

    /// Attempt to load config from disk. Returns nil on any failure (missing, corrupt).
    static func loadFromDisk(path: String) -> DaemonConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(DaemonConfig.self, from: data)
    }
}
