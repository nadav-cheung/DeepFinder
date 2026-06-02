/// Compile-time product configuration constants.
///
/// Centralizes all product names, paths, and identifiers in one place.
/// To rename the product, update only this file and `PRODUCT.toml` --
/// no other source files should contain the product name directly.
///
/// - Note: `PRODUCT.toml` is the authoritative source of truth for product naming.
///   This file provides the Swift-side compile-time representation.
///   May migrate to runtime config loading in a future version.
enum Product {

    // MARK: - Names

    /// Display name (used in help text, man page titles, REPL banner).
    static let name = "DeepFinder"

    /// URL-safe slug (used for GitHub repo, Homebrew formula name, directory names).
    static let slug = "deep-finder"

    /// CLI command name (used for binary name, shell completions, prompt).
    static let command = "deepfinder"

    /// Daemon binary name (spawned by CLI when daemon is not already running).
    static let daemonCommand = "deepfinder-daemon"

    /// macOS bundle identifier and LaunchAgent label.
    static let identifier = "com.nadav.deepfinder"

    // MARK: - Paths

    /// Root data directory for all DeepFinder runtime data.
    static let dataDir = "~/.deep-finder"

    // MARK: Subdirectories

    /// Cache directory for rebuildable data (SQLite index).
    static let cacheDir = "~/.deep-finder/cache"

    /// Logs directory for daemon and CLI log output.
    static let logsDir = "~/.deep-finder/logs"

    /// Session directory for runtime files (PID, socket, auth token).
    static let sessionDir = "~/.deep-finder/session"

    // MARK: Files

    /// User configuration file (JSON).
    static let configPath = "~/.deep-finder/settings.json"

    /// Secrets file for API keys and encryption keys (JSON, permissions 600).
    static let secretsPath = "~/.deep-finder/.env"

    /// Unix domain socket path for daemon IPC communication.
    static let socketPath = "~/.deep-finder/session/ipc.sock"

    /// Daemon PID file for singleton enforcement.
    static let pidPath = "~/.deep-finder/session/daemon.pid"

    /// HTTP API authentication token file.
    static let httpTokenPath = "~/.deep-finder/session/http-token"

    /// REPL command history file.
    static let historyPath = "~/.deep-finder/history"

    /// SQLite database path for persistent FileRecord storage.
    static let databasePath = "~/.deep-finder/cache/index.db"

    // MARK: - Version

    /// Current version string. Updated manually on each release.
    /// Kept in sync with the `VERSION` file at the repository root.
    static let version = "3.0.0"

    // MARK: - Organization

    /// Organization domain identifier.
    static let organization = "nadav.com.cn"

    /// Author name for packaging and documentation.
    static let author = "Nadav"
}
