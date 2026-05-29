import Foundation

/// 核心数据模型 — 表示文件系统中的一个文件或目录。
/// 所有文件名在入库前已做 NFC 统一化（precomposedStringWithCanonicalMapping）。
struct FileRecord: Codable, Sendable {
    let id: UInt32
    /// NFC 统一化后的文件名（用于搜索匹配）
    let name: String
    /// 原始文件名（保留原始形式用于显示）
    let originalName: String
    let path: String
    let parentPath: String
    let isDirectory: Bool
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
    /// 文件扩展名（不含点号），目录为 nil
    let `extension`: String?
}
