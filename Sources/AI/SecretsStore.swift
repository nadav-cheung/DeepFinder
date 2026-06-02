import Foundation
import OSLog

/// Errors from secrets file operations.
enum SecretsStoreError: Error, CustomStringConvertible {
    case saveFailed(String)
    case deleteFailed(String)

    var description: String {
        switch self {
        case .saveFailed(let reason):
            return "Secrets save failed: \(reason)"
        case .deleteFailed(let reason):
            return "Secrets delete failed: \(reason)"
        }
    }
}

/// File-backed secret storage replacing macOS Keychain.
///
/// Stores secrets as a flat JSON dictionary (`[String: String]`) at the configured
/// file path with permissions 600. Uses atomic writes (temp file + rename) to prevent
/// partial writes from corrupting the store.
///
/// **Thread safety**: Each call reads the file from disk, so concurrent writes from
/// separate processes may lose data. Within a single process, callers should serialize
/// access (e.g., via an actor). This struct is `Sendable` and can be used from any
/// concurrency domain.
///
/// **File format**:
/// ```json
/// {
///   "ai.apiKey": "sk-...",
///   "path_encryption_key_v1": "base64..."
/// }
/// ```
struct SecretsStore: Sendable {

    /// Path to the JSON secrets file on disk.
    let filePath: String

    private static let logger = Logger(subsystem: "com.nadav.deepfinder", category: "secrets")

    init(filePath: String = Product.secretsPath) {
        self.filePath = NSString(string: filePath).expandingTildeInPath
    }

    // MARK: - Public API

    /// Save a value. If the key already exists, updates it.
    func save(key: String, value: String) throws {
        var secrets = loadAll()
        secrets[key] = value
        try persist(secrets)
    }

    /// Load a value. Returns `nil` if the key doesn't exist or the file is missing/corrupted.
    func load(key: String) -> String? {
        loadAll()[key]
    }

    /// Delete a value. Returns `true` if the key existed and was removed.
    @discardableResult
    func delete(key: String) -> Bool {
        var secrets = loadAll()
        guard secrets[key] != nil else { return false }
        secrets.removeValue(forKey: key)
        do {
            try persist(secrets)
            return true
        } catch {
            Self.logger.error("Failed to persist after deleting key '\(key, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - File I/O

    /// Read all secrets from disk. Returns empty dict on any failure.
    private func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return [:]
        }
        if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        Self.logger.warning("Secrets file corrupted, starting fresh: \(self.filePath, privacy: .public)")
        return [:]
    }

    /// Write secrets to disk atomically with permissions 600.
    private func persist(_ secrets: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(secrets)

        let url = URL(fileURLWithPath: filePath)
        let dir = url.deletingLastPathComponent()

        // Ensure parent directory exists
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write to temp file in same directory (same filesystem for atomic rename)
        let tmpURL = dir.appendingPathComponent(".secrets.json.tmp.\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)

        // Set permissions before rename
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)

        // Atomic rename: remove existing file first (moveItem refuses to overwrite)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }
}
