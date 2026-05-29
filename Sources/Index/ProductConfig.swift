/// 产品配置常量。
///
/// 所有产品名、路径、标识符统一定义在此文件。
/// 修改产品名只需改此文件 + PRODUCT.toml，不散落到其他代码中。
///
/// - Note: PRODUCT.toml 是配置的唯一来源（source of truth）。
///   此文件是 Swift 侧的编译时常量表示。
///   未来可改为运行时读取 config.json（v0.4+）。
enum Product {

    // MARK: - 名称

    /// 显示名称（用于帮助文本、man page 标题、REPL banner）
    static let name = "DeepFinder"

    /// URL-safe slug（用于 GitHub repo、Homebrew formula 名）
    static let slug = "deep-finder"

    /// CLI 命令名（用于二进制文件名、shell completions、prompt）
    static let command = "deepfinder"

    /// macOS bundle identifier / LaunchAgent label
    static let identifier = "com.nadav.deepfinder"

    // MARK: - 路径

    /// 数据目录（索引、配置、日志）
    static let dataDir = "~/.deep-finder"

    /// Unix domain socket（daemon IPC）
    static let socketPath = "~/.deep-finder/ipc.sock"

    /// Daemon PID 文件
    static let pidPath = "~/.deep-finder/daemon.pid"

    /// 用户配置文件
    static let configPath = "~/.deep-finder/config.json"

    /// REPL 历史文件
    static let historyPath = "~/.deep-finder/history"

    /// SQLite 数据库
    static let databasePath = "~/.deep-finder/index.db"

    // MARK: - 组织

    static let organization = "nadav.com.cn"
    static let author = "Nadav"
}
