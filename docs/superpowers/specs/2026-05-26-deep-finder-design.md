# DeepFinder - macOS Design Spec

对标 Windows Everything 的 macOS 极速文件搜索工具。

## 项目概要

| 项目 | 值 |
|------|-----|
| 名称 | deep-finder |
| 平台 | macOS only, Apple Silicon M4+ |
| 最低系统 | macOS 26 (Tahoe) |
| 架构 | arm64 only |
| 技术栈 | Swift (zero external deps) |
| 应用形态 | v1.0 CLI（daemon + REPL + single-shot），v2.0 加 GUI（Menu Bar App），v3.0 加 AI 语义搜索 |
| 开源 | 是 |
| 数据目录 | ~/.deep-finder/ |
| 分发渠道 | v1.0: GitHub Releases + Homebrew formula, v2.0: + Cask |

## 功能路线图

渐进式开发。v1.0 = CLI-first，v2.0 = 加 GUI。每个版本独立可用。

**设计原则**：性能优先，内存/CPU 不受约束。SearchProvider 协议 + 插件式架构确保新功能不影响现有代码。

### v1.0 — CLI 搜索（v0.1–v0.7 总集 + 打磨）

> v1.0 是首个面向用户的完整发布版本。v0.1–v0.7 是渐进式开发里程碑。

| 功能 | 说明 |
|------|------|
| 文件名搜索 | 前缀 + 任意子串 + 拼音（FullSubstringMap O(1)) |
| 实时监控 | FSEvents 增量更新 |
| Daemon 架构 | 后台常驻进程，持有完整内存索引，Unix socket IPC |
| Single-shot CLI | `deepfinder "query"` → 输出结果 → 退出 |
| Interactive REPL | `deepfinder` → 交互循环：搜索、:open、:stats、:config 等 |
| 终端格式化 | ANSI 颜色、匹配高亮、--json、--0（null 分隔） |
| 拼音搜索 | CFStringTokenizer → 拼音 Trie，支持首字母缩写 |
| NFC 统一化 | 所有文件名 NFC 统一化，避免 Unicode 比较问题 |
| 持久化索引 | SQLite WAL，启动重建 <5s |
| Daemon 管理 | daemon start/stop/restart/install（LaunchAgent） |
| 配置管理 | config get/set/list（~/.deep-finder/config.json） |
| Homebrew | formula 分发（not cask，因为是 CLI 工具） |
| Man page + completions | bash/zsh/fish shell completions |

### v1.1 — 高级搜索语法

对标 Everything 搜索语法。

| 功能 | 示例 | 说明 |
|------|------|------|
| 布尔运算符 | `ABC 123` (AND), `ABC\|123` (OR), `!ABC` (NOT) | 空格=AND, \|=OR, !=NOT |
| 通配符 | `*.pdf`, `report_??.xlsx` | `*` 任意字符, `?` 单字符 |
| 正则表达式 | `regex:^report_\d{4}` | regex: 前缀激活 |
| 路径限定 | `Documents\ report`, `parent:~/Documents` | 路径内搜索 |
| 修饰符 | `case:`, `file:`, `folder:`, `ext:pdf;doc`, `path:` | 搜索选项控制 |
| 搜索历史 | REPL 内 ↑↓ 回溯，持久化最近 1000 条 | readline history |

### v1.2 — 元数据过滤

对标 Everything functions（size:, dm:, ext: 等）。

| 功能 | 示例 | 说明 |
|------|------|------|
| 大小过滤 | `size:>1mb`, `size:100kb..10mb` | 支持 kb/mb/gb 单位和范围 |
| 日期过滤 | `dm:today`, `dc:thisweek`, `dm:2026-01-01..2026-03-31` | 创建/修改/访问日期 |
| 扩展名过滤 | `ext:pdf;doc;xlsx` | 分号分隔多扩展名 |
| 类型过滤 | `audio:`, `video:`, `pic:`, `doc:` | 预定义文件类型宏 |
| 文件/文件夹 | `file:`, `folder:` | 限定结果类型 |
| 路径深度 | `depth:3` | 限定目录层级 |

### v1.3 — 搜索体验

| 功能 | 说明 |
|------|------|
| 书签 | 保存搜索+排序+过滤，一键恢复 |
| 自定义过滤器 | 预定义搜索条件 + 快捷宏 |
| 结果排序 | 名称/大小/日期/扩展名/路径，自然排序 |
| 排序持久化 | 记住上次排序方式 |
| 自动补全 | 基于历史和热门文件的本地补全 |

### v1.4 — 内容搜索

| 功能 | 示例 | 说明 |
|------|------|------|
| 内容搜索 | `*.eml dm:thisweek content:banana` | 流式读取 |
| 编码支持 | UTF-8, UTF-16, UTF-16BE | 自动检测 |
| 文件类型限定 | `ext:swift;py;md content:TODO` | 只搜索特定扩展名 |
| 行号定位 | 结果显示匹配行号 | 仅文本文件 |

### v1.5 — 重复文件

| 功能 | 示例 | 说明 |
|------|------|------|
| 按名称查重 | `dupe:` | 相同文件名 |
| 按大小查重 | `size:>1mb sizedupe:` | 相同大小 |
| 按内容哈希查重 | `hashdupe:` | SHA-256 |
| 空文件夹 | `empty:` | 空目录 |
| 文件名长度 | `len:>100` | 超长文件名 |

### v2.0 — GUI + 扩展索引

| 功能 | 说明 |
|------|------|
| NSPanel + Liquid Glass | Spotlight 风格浮动窗口 |
| Apple Intelligence 光晕 | 多色旋转描边 |
| 全局热键 | ⌃⌘K 唤起 |
| Menu Bar App | LSUIElement=true |
| Quick Look | Space 预览 |
| 右键菜单 | Finder 中显示 / 复制路径 / 拖拽 |
| 外置卷索引 | USB/Thunderbolt，卸载时保留索引 |
| 网络卷索引 | SMB/AFP/NFS |

### v2.1 — 媒体元数据

| 功能 | 示例 | 说明 |
|------|------|------|
| 图片尺寸 | `width:>2560` | EXIF 元数据 |
| 音频标签 | `artist:周杰伦` | ID3/AAC 元数据 |
| 视频信息 | `duration:>300` | AVFoundation |
| PDF 元数据 | `pdf-author:xxx` | PDFKit |

### v2.2 — 服务与集成

| 功能 | 说明 |
|------|------|
| HTTP 搜索服务 | 本地 Web 界面 |
| URL Scheme | `deepfinder://search?q=keyword` |
| Shortcuts | Apple Shortcuts 动作 |
| AppleScript | 脚本化搜索 |

### v3.0 — AI 辅助搜索

超越 Everything 的下一代功能。接入 DeepSeek、千问等在线文本模型和视觉模型辅助搜索。

**核心约束：全部文件不离开本地。**

#### 隐私边界

| 数据类型 | 本地 | 允许外传 | 说明 |
|----------|------|----------|------|
| 文件内容 | ✅ | ✗ | 任何格式的文件二进制数据，永不外传 |
| 文件缩略图 | ✅ | ✗ | 图片像素数据，永不外传 |
| 文件名/路径 | ✅ | ✓ | 元数据可发送到云端辅助理解 |
| 文件大小/日期/扩展名 | ✅ | ✓ | 元数据可发送到云端辅助理解 |
| 用户搜索文本 | ✅ | ✓ | 查询文本发送到云端理解意图 |
| 本地生成的标签 | ✅ | ✓ | CoreML/Vision 生成的文本标签 |
| 路径中的用户名 | 脱敏 | ✓ | `/Users/nadav/` → `~/`（默认开启脱敏）|

#### AI 能力分工

| 能力 | 本地（CoreML / Vision） | 云端（DeepSeek / Qwen） |
|------|------------------------|------------------------|
| 图片理解 | ✅ Vision 框架生成描述文本 + 场景/物体标签 | ✗ 图片不外传 |
| 文件标签 | ✅ 本地 CoreML 分类 | ✅ 根据文件名/路径元数据推断语义标签 |
| 自然语言 → 搜索语法 | ✗ 需要 LLM 能力 | ✅ "找上周改过的大文件" → `dm:lastweek size:>10mb` |
| 结果摘要 | ✗ | ✅ 基于元数据生成摘要 |
| AI 搜索建议 | ✗ | ✅ 基于结果元数据生成优化建议 |
| 语音搜索 | ✅ 本地 Speech 框架语音识别 | ✅ 文本送云端理解意图 |

#### AIProvider 协议设计

```swift
/// AI 能力定义
enum AICapability: String, Sendable, Codable, CaseIterable {
    case textToSearch       // 自然语言 → 搜索语法
    case resultSummary      // 结果摘要 & 分类
    case querySuggestion    // AI 搜索建议
    case intentAnalysis     // 意图理解
    case localVision        // 本地图片理解（Vision 框架，完全本地）
    case localSpeech        // 本地语音识别（Speech 框架，完全本地）
}

/// 隐私安全的元数据摘要 — 唯一允许外传的数据结构
struct FileMetadataSummary: Sendable {
    let name: String
    let path: String           // 脱敏后：/Users/xxx → ~/
    let size: Int64
    let modifiedAt: Date
    let `extension`: String?
    let localTags: [String]?   // CoreML/Vision 生成的标签
}

/// AI 上下文 — 发送给云端模型的全部信息
struct AIContext: Sendable {
    let query: String
    let resultMetadata: [FileMetadataSummary]
    let indexStats: IndexStats
}

/// AI 模型提供者协议（单一协议设计）
///
/// 所有 AI 后端（云端 API 和本地框架）都实现此协议。
/// 通过 `capabilities: Set<AICapability>` 区分支持的能力：
/// - 云端提供商（DeepSeek/Qwen）：textToSearch, resultSummary, querySuggestion, intentAnalysis
/// - 本地 Vision：localVision
/// - 本地 Speech：localSpeech
///
/// 能力系统允许：
/// - 跳过活动提供商不支持的功能
/// - 混合提供商：文本提供商用于搜索翻译 + 本地 Vision 用于图片分析
/// - 优雅降级：当 `provider` 为 `nil` 时所有消费者返回 `nil`/空
///
/// 添加新提供商只需一个实现此协议的新文件，无需修改现有代码。
protocol AIModelProvider: Sendable {
    /// 可读的提供商名称（如 "deepseek", "qwen", "mock"）
    var name: String { get }

    /// 此提供商支持的能力集
    var capabilities: Set<AICapability> { get }

    /// 对给定提示进行流式补全，可选附带搜索上下文。
    ///
    /// 返回 `AsyncThrowingStream` 用于流式（逐 token）响应。
    /// 调用方在 token 到达时逐块消费；错误通过流的终端事件（`.failure`）传播。
    /// 调用方应使用 `for try await` 并在迭代处捕获错误，优雅回退（如返回 `nil`）。
    ///
    /// **错误传播**：流可能以以下方式结束：
    /// - `AIError.rateLimited`（HTTP 429）
    /// - `AIError.networkError`（HTTP 4xx/5xx，传输失败）
    /// - `CancellationError`（如果消费 Task 在流中取消）
    ///
    /// **隐私**：context 仅包含文件元数据（名称、大小、日期、扩展名）—— 绝不包含文件内容。
    func complete(prompt: String, context: AIContext?) -> AsyncThrowingStream<String, Error>

    /// 将自然语言查询翻译为 DeepFinder 搜索语法。
    ///
    /// 示例："find big videos from last week" → "ext:mp4;mov;mkv dm:lastweek size:>100mb"
    ///
    /// - Parameter naturalLanguage: 用户的自然语言输入。
    /// - Returns: 有效的 DeepFinder 搜索语法字符串。
    func translateToSearchSyntax(naturalLanguage: String) async throws -> String
}
```

### v3.1+ — 本地 RAG 与 AI 增强

v3.1 及后续版本的 AI 技术栈演进路线见独立设计文档：

- **AI 技术栈设计**: `docs/superpowers/specs/2026-06-01-ai-tech-stack-design.md` — v3.1→v3.3 完整路线（多提供商、Embedding、VectorStore、OCR、SpeechAnalyzer）
- **v3.1 RAG REQ**: `docs/superpowers/specs/reqs/v3.1-rag.md` — 文件分块、本地 Embedding、向量索引、语义检索、本地生成（7 REQ，未开始）

---

## 1. 系统架构

### v1.0 CLI 架构

```
┌─────────────────────────────────────────────────────────────┐
│                     CLI Process (deepfinder)                │
│  ┌─────────────────────┐  ┌──────────────────────────────┐  │
│  │   Single-Shot Mode   │  │     Interactive REPL Mode    │  │
│  │ deepfinder "query"   │  │     deepfinder (no args)     │  │
│  │ --json/--0/--sort    │  │  :help :stats :open N :quit  │  │
│  └──────────┬───────────┘  └──────────────┬───────────────┘  │
│             └──────────┬──────────────────┘                  │
│                   IPCClient                                  │
│             (Unix Domain Socket)                             │
└──────────────────────┬──────────────────────────────────────┘
                       │ ~/.deep-finder/ipc.sock
┌──────────────────────▼──────────────────────────────────────┐
│                  Daemon Process (deepfinder-daemon)          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    IPCServer                          │  │
│  │  socket accept → JSON decode → dispatch → JSON encode │  │
│  └──────────────┬───────────────────────────────────────┘  │
│                 │                                             │
│  ┌──────────────▼───────────────────────────────────────┐  │
│  │              SearchCoordinator (actor)                │  │
│  │  - 分发查询给 SearchProvider                          │  │
│  │  - 合并 & 排序结果                                    │  │
│  └──────┬───────────────┬───────────────────┬───────────┘  │
│         │               │                   │               │
│  ┌──────▼──────┐  ┌─────▼────────┐  ┌──────▼────────────┐  │
│  │ FileIndex   │  │  (future     │  │  AISearchCoord    │  │
│  │  Provider   │  │  providers)  │  │  (v3.0)           │  │
│  └──────┬──────┘  └──────────────┘  └───────────────────┘  │
│         │                                                    │
│  ┌──────▼──────────────────────────────────────────────┐   │
│  │     InMemoryIndex (actor)                            │   │
│  │  - Trie (前缀匹配)                                   │   │
│  │  - FullSubstringMap (子串 O(1) 直查)                 │   │
│  │  - TrigramIndex (长文件名兜底)                       │   │
│  │  - PinyinIndex (拼音搜索)                            │   │
│  │  - FileRecord[] (路径、大小、日期)                   │   │
│  └──┬───────────────────────────────┬──────────────────┘   │
│     │                               │                       │
│  ┌──▼──────────────┐  ┌─────────────▼──────────────────┐   │
│  │  FileScanner    │  │ FileSystemEventStream          │   │
│  │                 │  │  (FSEventWatcher)              │   │
│  └─────────────────┘  └────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  IndexPersistence (SQLite WAL)                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  PID file: ~/.deep-finder/daemon.pid                        │
│  Socket: ~/.deep-finder/ipc.sock                            │
│  Signal: SIGTERM/SIGINT → graceful shutdown                 │
└──────────────────────────────────────────────────────────────┘
```

### v2.0 GUI 复用同一 Daemon

```
┌──────────────────────────────────────┐
│       GUI Process (v2.0)             │
│  NSPanel + Liquid Glass + Hotkey     │
│         IPCClient                    │
└──────────────┬───────────────────────┘
               │ same socket
┌──────────────▼───────────────────────┐
│       Daemon Process (unchanged)     │
│  一 Daemon 服务 CLI + GUI 两个客户端   │
└──────────────────────────────────────┘
```

### 模块职责

> **Note**: The following table describes logical module responsibilities. Currently all modules live in a single `DeepFinder` library target (see Section 8). Splitting into separate sub-library targets is planned to improve build parallelism and enforce module boundaries.

| 模块 | 职责 | Target |
|------|------|--------|
| **DeepFinder** (library) | 共享库：Index + Search + FS + Persist + Daemon + CLI + GUI + AI + Media + Services | library |
| **DeepFinderCLI** | CLI 入口：main.swift → CLIMain | executable |
| **DeepFinderDaemon** | Daemon 入口：main.swift → DaemonMain | executable |
| **DeepFinderApp** | GUI App 入口：main.swift → AppDelegate (v2.0+) | executable |

### 依赖方向

```
DeepFinderCLI ──depends on──→ DeepFinder (library)
DeepFinderDaemon ──depends on──→ DeepFinder (library)
DeepFinderApp ──depends on──→ DeepFinder (library)
```

依赖单向向下，无循环。Index 层不依赖 CLI/Daemon，可独立测试。

### 并发模型

```
InMemoryIndex: actor
  - 所有读/写操作通过 actor isolation 保证线程安全
  - 快照读 API: snapshot() -> IndexSnapshot (不可变)

FileScanner + FSEventWatcher: 由 DaemonMain 管理生命周期
  - FileScanner 在后台 DispatchQueue 上运行，完成后通过 InMemoryIndex actor 方法写入
  - FSEventWatcher 分发到独立 DispatchQueue，通过 InMemoryIndex actor 方法写入

SearchCoordinator: plain actor (NOT @MainActor)
  - daemon 无 UI 上下文，不需要主线程
  - v2.0 GUI 层在 client 端做 @MainActor 包装
```

### 索引状态机

```
         ┌──────────┐
         │  stale    │ ← 加载持久化索引后（可能过时）
         └────┬─────┘
              │ 后台验证 + FSEvents 已启动
              ▼
         ┌──────────┐
         │ verifying │ ← 全量扫描验证中
         └────┬─────┘
              │ 验证完成
              ▼
         ┌──────────┐
         │   live    │ ← FSEvents 实时更新
         └────┬─────┘
              │ FSEvents 停止
              ▼
         ┌──────────┐
         │   error   │ ← FSEvents 异常停止 / 验证超时
         └────┬─────┘
              │ 恢复尝试
              ▼
         ┌──────────┐
         │  stale    │ ← 重新验证
         └──────────┘
```

CLI 通过 `:stats` 命令或 `deepfinder daemon status` 查看索引状态。

---

## 2. 索引引擎

### 2.1 数据模型

```swift
struct FileRecord: Codable, Sendable {
    let id: UInt32
    let name: String            // 文件名（NFC 统一化）
    let originalName: String    // 原始文件名（保留原始形式用于显示）
    let path: String
    let parentPath: String
    let isDirectory: Bool
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
    let `extension`: String?
}

struct UsageStats {
    let openCount: Int
    let lastOpenedAt: Date?
}
```

所有文件名入库前做 **NFC 统一化**（`name.precomposedStringWithCanonicalMapping`），查询时同样统一化。

**大小写处理**：默认不区分大小写。FullSubstringMap 的 key 统一用 `.lowercased()` 存储，查询时同样 `.lowercased()`。显示时使用 `originalName` 保留原始大小写。

### 2.2 索引结构（速度优先）

| 索引 | 结构 | 用途 | 查询速度 | 内存/文件 |
|------|------|------|----------|-----------|
| Trie | Unicode scalar 字典树 | 前缀匹配、即时补全 | O(k) | O(n) |
| FullSubstringMap | 子串 → [FileRecord.ID] 直接映射 | 任意子串 O(1) 命中 | O(1) | O(n²) |
| TrigramIndex | trigram → [FileRecord.ID] posting list | 长文件名(>64字符)子串匹配 | O(1) → 交集 → 验证 | O(n) |

**设计原则：速度第一，内存不是瓶颈。**

- 文件名 ≤64 字符：建全子串映射（所有子串直接指向 FileRecord.ID），查询 O(1) 零计算
- 文件名 >64 字符：退化为 trigram + 交集验证
- M4+ 统一内存架构，1M 文件的全子串映射约占 8-10GB。超过内存上限时降级为 TrigramIndex

**FullSubstringMap 工作原理：**

```
文件名 "report.pdf" (11 chars) 的所有子串:
"r", "re", "rep", ..., "report.pdf", "e", "ep", ..., "df"
每个子串 → 直接映射到 FileRecord.ID

查询 "port": 直接查 HashMap["port"] → 结果
无需交集计算，无需验证，零延迟
```

**拼音索引（中文用户强需求）：**

```
文件名 "季度报告.pdf" → CFStringTokenizer 分词 + CFStringTransform 拼音化:
全拼: "ji", "du", "bao", "gao"
首字母: "j", "d", "b", "g" → 拼接 "jdbg"

用户输入 "baogao" → 全拼 Trie 命中
用户输入 "jdbg"   → 首字母 Trie 命中
```

PinyinIndex 构建两个 Trie：(1) 全拼 Trie；(2) 首字母 Trie。CFStringTokenizer 负责中文分词，CFStringTransform 负责转拼音。

### 2.3 全量扫描

- `FileManager.enumerator(at:rootURL, ...)` 遍历所有卷
- 跳过：`/System`, `/Library`, `.Trash`, `.git`, `node_modules`, `.Spotlight-V100`，可配置
- 默认排除隐私目录：`~/Library/Caches`, `~/Library/Cookies`, `~/Library/Keychains`
- 只索引当前用户 home 目录 + 系统共享目录
- **外置磁盘/网络卷**：全部索引，卸载时从索引移除
- **符号链接**：默认不 follow，循环通过 visited-set 检测
- `TaskGroup` 按卷并行扫描
- 边扫边建索引

### 2.4 FSEvents 增量更新

```swift
protocol FileSystemEventStream: Sendable {
    func start(paths: [String], handler: @escaping @Sendable ([(String, FSEventStreamEventFlags)]) -> Void)
    func stop()
    var isRunning: Bool { get }
}

// 生产实现：FSEventStreamSetDispatchQueue（非 deprecated RunLoop API）
final class FSEventStreamImpl: FileSystemEventStream { ... }

// 测试实现
final class MockEventStream: FileSystemEventStream { ... }
```

| 事件 | 操作 |
|------|------|
| 文件创建 | 插入索引 |
| 文件删除 | 移除索引 |
| 文件重命名 | 删除旧记录 + 插入新记录 |
| 文件修改 | 更新元数据 |

**启动衔接流程：**

```
1. 加载持久化索引 → indexState = .stale → 立即可搜索
2. 启动 FSEventStream（lastEventId as sinceWhen → 回放历史）
3. 后台全量验证 → indexState = .verifying
4. 验证完成 → indexState = .live
```

### 2.5 持久化

```
~/.deep-finder/
├── index.db          # SQLite WAL 模式
├── config.json       # 用户配置
├── ipc.sock          # Unix domain socket (daemon 运行时)
├── daemon.pid        # PID 文件
├── history           # REPL 历史记录
└── log/              # 运行日志
```

**权限**：目录 700，文件 600。

**持久化策略：**
- SQLite 存储 `FileRecord[]`
- 不持久化索引结构 → 启动时从 FileRecord[] 重建（<5s 中文，<3s 英文）
- 增量持久化：每 5s 或每 100 条变更批量写入
- Schema 版本管理：`PRAGMA user_version`，事务内迁移，失败 rollback + 全量重建
- 索引损坏恢复：加载时校验，失败删除重建

---

## 3. SearchProvider 协议 & 搜索流程

### 3.1 协议

#### SearchResultSequence

The `SearchProvider` protocol returns a concrete `SearchResultSequence` (not an
existential `any AsyncSequence`) so that results can safely cross actor
boundaries — the existential is not `Sendable`. MVP providers wrap a
pre-computed `[SearchResult]`; future streaming providers can yield
incrementally within the same wrapper:

```swift
struct SearchResultSequence: AsyncSequence, Sendable {
    typealias Element = SearchResult
    init(_ elements: [SearchResult])
    func makeAsyncIterator() -> Iterator
    struct Iterator: AsyncIteratorProtocol, Sendable { … }
}
```

#### SearchProvider

```swift
protocol SearchProvider: Sendable {
    /// Stable identifier for this provider (e.g. "file-index", "content-search").
    var providerID: String { get }

    func search(query: SearchQuery) async -> SearchResultSequence
    func cancel(queryID: String) async
    func prepare() async
}
```

Providers are the unit of extensibility for search: different providers can
search different data sources (in-memory index, content search, AI semantic
search) while sharing the same `SearchQuery` / `SearchResult` types.

- `providerID` — stable, unique identifier (e.g. `"file-index"`).
- `search(query:)` — returns results wrapped in `SearchResultSequence`.
- `cancel(queryID:)` — cancels an in-flight query. No-op for synchronous MVP
  providers; required for future streaming providers.
- `prepare()` — one-time async setup (e.g. loading an index from disk). No-op
  for in-memory providers.

#### SearchQuery

```swift
struct SearchQuery: Sendable {
    /// Original user input, unmodified.
    let rawQuery: String
    /// NFC-normalized + lowercased form (used for matching).
    let normalizedQuery: String

    init(_ query: String)
}
```

On init the query is NFC-normalized via `precomposedStringWithCanonicalMapping`
and lowercased. The raw form is preserved for display.

#### SearchResult

```swift
struct SearchResult: Codable, Sendable, Equatable {
    let record: FileRecord
    /// Identifier of the provider that produced this result (e.g. "file-index").
    let providerID: String
    let score: Double
    let matchType: MatchType

    /// Equality by record.id for deduplication.
    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool
}
```

#### MatchType

```swift
enum MatchType: Int, Codable, Comparable, Sendable {
    /// The query exactly matches the full filename (case-insensitive).
    case exact = 0
    /// The query matches the beginning of the filename.
    case prefix = 1
    /// The query matches via pinyin transliteration of Chinese characters.
    case pinyin = 2
    /// The query appears as a substring anywhere in the filename.
    case substring = 3
}
```

Lower `rawValue` equals higher priority, driving result ordering (exact before
prefix before pinyin before substring). `MatchType` is `Comparable` via
`rawValue`.

### 3.2 SearchCoordinator

plain actor（NOT @MainActor）。daemon 进程无 UI 上下文。v2.0 GUI client 端做 @MainActor 包装。

**分页**：默认 100 条，CLI 通过 --limit/--offset 翻页，REPL 通过 :more 加载更多。

### 3.3 排序策略

| 因素 | 权重 | 说明 |
|------|------|------|
| MatchType | 最高 | exact > prefix > pinyin > substring |
| 文件名长度 | 高 | 短名优先 |
| 使用频率 | 高 | openCount 越高越优先 |
| 修改时间 | 中 | 最近修改优先 |
| 路径深度 | 低 | 浅路径优先 |

---

## 4. Daemon & IPC（v0.4）

### 4.1 Daemon 进程

**入口**：`DaemonMain.swift`

**启动序列：**
1. 加载 `~/.deep-finder/config.json`（不存在则用默认配置）
2. 加载 SQLite FileRecord[]，重建 InMemoryIndex
3. 启动 FSEventWatcher + 后台验证
4. 清理旧 socket 文件（unlink），创建 Unix domain socket
5. 绑定 socket → 开始监听
6. 写 PID 到 `~/.deep-finder/daemon.pid`
7. 注册 SIGTERM/SIGINT 处理
8. 进入 DispatchMain() 运行循环

**关闭序列（SIGTERM handler）：**
1. 停止接受新连接
2. 关闭所有 client 连接
3. flush 剩余变更到 SQLite
4. 保存 FSEvents cursor (lastEventId)
5. 删除 socket 文件和 PID 文件
6. exit(0)

**LaunchAgent plist**（`deepfinder daemon install` 生成）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nadav.deepfinder.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/deepfinder</string>
        <string>daemon</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/deepfinder-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/deepfinder-daemon.err</string>
</dict>
</plist>
```

**注意**：launchd 管理时不调用 daemon()/fork()/setsid()，launchd 禁止这些调用。

### 4.2 IPC 协议

**传输层**：Unix domain socket at `~/.deep-finder/ipc.sock`

**帧格式**：4-byte big-endian UInt32 长度前缀 + UTF-8 JSON body

```
[4 bytes: payload length N as big-endian UInt32][N bytes: UTF-8 JSON]
```

**为什么选 length-prefix 而非 newline-delimited JSON**：
- JSON 内部不含转义问题
- 消息边界明确
- 支持未来 binary payload
- 与 gRPC 等协议一致

**信号处理**：进程启动时 `signal(SIGPIPE, SIG_IGN)` 防止 broken pipe 崩溃。

**并发连接**：DispatchSourceRead 监听 listen fd，每个 client fd 创建独立 DispatchSourceRead。

### 4.3 IPC 消息类型

消息格式为 flat enum -- 不使用嵌套 payload struct。每个 request/response 通过 `kind` 字段鉴别类型，
`ipcProtocolVersion` 字段嵌入每个 request 用于前向兼容。

**Wire format example (query):**
```json
{"ipcProtocolVersion":1,"kind":"query","query":"report","limit":100}
```

```swift
// MARK: - Protocol Version

/// Embedded in every encoded request for forward compatibility.
/// Incremented when the wire format changes in a non-backward-compatible way.
let ipcProtocolVersion = 1

// MARK: - IPCError

/// Fine-grained error types returned in IPC error responses.
enum IPCError: Codable, Sendable, Equatable, Error {
    case daemonNotReady
    case queryError(String)
    case invalidRequest(String)
    case permissionDenied(String)
    case incompatibleProtocolVersion
}

// MARK: - IPCRequest

/// All message types a client can send to the daemon (flat enum, 6 cases).
enum IPCRequest: Codable, Sendable, Equatable {
    /// Execute a search query with an optional result limit.
    case query(_ query: String, limit: Int?)
    /// Cancel an in-flight query by its identifier.
    case cancel(queryID: String)
    /// Request daemon statistics (file count, uptime, memory usage).
    case stats
    /// Read one or all configuration values. Pass `nil` for all keys.
    case configGet(key: String?)
    /// Update a single configuration key-value pair.
    case configSet(key: String, value: String)
    /// Request current index state and file count.
    case indexStatus
}

// MARK: - DaemonStats

/// Runtime statistics reported by the daemon.
struct DaemonStats: Codable, Sendable, Equatable {
    let totalFiles: Int
    let indexState: String        // e.g. "live", "verifying", "polling"
    let uptimeSeconds: Double
    let memoryUsageMB: Double
}

// MARK: - DaemonIndexStatus

/// Current state of the file index as reported by the daemon.
struct DaemonIndexStatus: Codable, Sendable, Equatable {
    let state: String             // e.g. "stale", "verifying", "live", "polling"
    let filesIndexed: Int
    let lastScanDate: Date?
}

// MARK: - IPCResponse

/// All message types the daemon can send back to a client (flat enum, 5 cases).
enum IPCResponse: Codable, Sendable, Equatable {
    case results([SearchResult], queryID: String)
    case error(IPCError)
    case stats(DaemonStats)
    case ack
    case indexStatus(DaemonIndexStatus)
}

// MARK: - IPCFraming

/// Wire-framing helpers. 4-byte big-endian UInt32 length prefix + JSON body.
enum IPCFraming {
    static func addLengthPrefix(to payload: Data) -> Data
    static func stripLengthPrefix(from data: Data) throws -> Data
    static func encode<T: Codable>(_ value: T) throws -> Data
    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T
}

// MARK: - IPCFramingError

enum IPCFramingError: Error, Sendable {
    case insufficientHeader
    case incompletePayload(expected: Int, actual: Int)
}
```

### 4.4 Daemon 管理（v0.7）

| 子命令 | 行为 |
|--------|------|
| `deepfinder daemon run` | 前台运行 daemon（调试用） |
| `deepfinder daemon start` | 后台启动 daemon |
| `deepfinder daemon stop` | SIGTERM → 等待退出 |
| `deepfinder daemon restart` | stop + start |
| `deepfinder daemon status` | 连接 daemon → IPC status query |
| `deepfinder daemon install` | 生成 LaunchAgent plist + launchctl load |
| `deepfinder daemon uninstall` | launchctl unload + 删除 plist |

---

## 5. CLI 层（v0.5-v0.6）

### 5.1 入口 & 参数解析

手动解析 `CommandLine.arguments`（零外部依赖）。

```
deepfinder                          # 无参数 → REPL 模式
deepfinder <query> [flags]          # 单次查询
deepfinder daemon <subcommand>      # daemon 管理
deepfinder config <subcommand>      # 配置管理
deepfinder --help / -h              # 帮助
deepfinder --version / -v           # 版本
```

**查询 flags：**

| Flag | 说明 |
|------|------|
| `--json` | JSON 输出（脚本友好） |
| `--0` / `--null` | null 字符分隔路径（管道安全） |
| `--limit N` | 限制结果数 |
| `--offset N` | 偏移量 |
| `--sort name\|size\|date\|ext` | 排序方式 |
| `--type file\|folder` | 结果类型过滤 |
| `--color=auto\|always\|never` | 颜色控制 |
| `--highlight` | 匹配高亮（默认开启） |

**exit codes：**

| Code | 含义 |
|------|------|
| 0 | 成功 |
| 1 | 无结果 |
| 2 | daemon 连接错误 |
| 3 | 查询错误 |
| 4 | 参数错误 |

### 5.2 REPL 交互模式

使用 Darwin.readline (libedit) — macOS 自带，零依赖。

```swift
// readline 声明
@_silgen_name("readline")
func readline(_ prompt: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("add_history")
func add_history(_ line: UnsafePointer<CChar>)

@_silgen_name("read_history")
func read_history(_ filename: UnsafePointer<CChar>) -> Int32

@_silgen_name("write_history")
func write_history(_ filename: UnsafePointer<CChar>) -> Int32
```

**REPL 命令：**

| 命令 | 说明 | IPC 消息 |
|------|------|----------|
| `<search text>` | 搜索文件 | query |
| `:help` | 显示帮助 | 无 |
| `:quit` / Ctrl+D | 退出 REPL | 无 |
| `:stats` | 索引统计 | status |
| `:config <key>` | 查看配置 | configGet |
| `:config <key> <value>` | 设置配置 | configSet |
| `:daemon` | daemon 状态 | status |
| `:refresh` | 重建索引 | indexRebuild |
| `:open N` | 打开第 N 个结果 | NSWorkspace.open |
| `:reveal N` | Finder 中定位 | NSWorkspace.selectFile |
| `:copy-path N` | 复制路径到剪贴板 | NSPasteboard |
| `:info N` | 显示文件详情 | query (single) |
| `:more` | 加载更多结果 | query (next offset) |

**历史**：持久化到 `~/.deep-finder/history`，最多 1000 条。readline 提供上下箭头浏览。

**信号**：
- Ctrl+C：中断当前查询，返回 prompt（不退出 REPL）
- Ctrl+D：退出 REPL

### 5.3 终端格式化

**TTY 检测**：`isatty(STDOUT_FILENO)` → 非 TTY 时自动禁用 ANSI 颜色。同时尊重 `NO_COLOR` 和 `FORCE_COLOR` 环境变量。

**颜色方案（ANSI 16-color）：**

| 元素 | 样式 | ANSI code |
|------|------|-----------|
| 文件名 | bold green | `\u{001B}[1;32m` |
| 目录名 | bold blue | `\u{001B}[1;34m` |
| 匹配高亮 | bold cyan | `\u{001B}[1;36m` |
| 路径 | dim | `\u{001B}[2m` |
| 元数据（大小/日期） | dim | `\u{001B}[2m` |
| 错误 | red | `\u{001B}[31m` |
| 提示符 | bold | `\u{001B}[1m` |

**输出格式（人类可读）：**

```
  1  report.pdf          ~/Documents/reports/     2.3 MB  2026-05-20
  2  Q2-report.xlsx      ~/Desktop/               156 KB  2026-05-18
  3  weekly_report.md    ~/Projects/docs/         12 KB   2026-05-15
```

匹配部分（如 "report"）高亮显示。

**JSON 输出（--json）：**

```json
[
  {
    "name": "report.pdf",
    "path": "/Users/user/Documents/reports/report.pdf",
    "isDirectory": false,
    "size": 2411724,
    "modifiedAt": "2026-05-20T10:30:00Z",
    "extension": "pdf",
    "matchRange": [0, 6]
  }
]
```

**Null 分隔（--0）：**

```
/Users/user/Documents/reports/report.pdf\0/Users/user/Desktop/Q2-report.xlsx\0
```

### 5.4 Daemon 自动启动

CLI 检测 daemon 是否运行：
1. 检查 socket 文件是否存在
2. 检查 PID 文件 → `kill(pid, 0)` 验证进程存活
3. 尝试连接 socket
4. 连接失败 → 启动 daemon（`Process /usr/local/bin/deepfinder daemon run &`）
5. 轮询 socket 文件，最多等待 5s
6. 仍然失败 → stderr 错误提示，exit code 2

---

## 6. v2.0 GUI 层（已实现）

v2.0 已完全实现 — 19 个源文件在 `Sources/GUI/`，测试在 `Tests/GUITests/`。GUI 作为独立 IPC client 连接 daemon，daemon 和 IPC 协议不变。

### 6.1 应用入口 & 菜单栏

- `DeepFinderAppDelegate: NSApplicationDelegate` — 应用入口（非 `@main`，由外部 app target 设置 delegate 后启动）
- `NSApp.setActivationPolicy(.accessory)` — LSUIElement，无 Dock 图标，无主菜单
- `StatusBarController` — NSStatusItem 菜单栏图标（magnifyingglass SF Symbol），左键切换面板，右键上下文菜单（搜索/设置/退出）
- 自动启动 daemon：`applicationDidFinishLaunching` 中通过 `IPCClient.ensureDaemonRunning()` 确保 daemon 运行
- 组件间通过 `NotificationCenter` 通信（`.toggleSearchPanel`, `.showSettings`）

### 6.2 搜索面板（NSPanel）

- `SearchPanelHostingController` — 管理 NSPanel 生命周期
- `.nonactivatingPanel` + `.fullSizeContentView` + `.borderless` 样式
- `.floating` 窗口层级，无标题栏
- 居中于鼠标所在屏幕（`screenForMouseLocation()`），非固定顶部居中
- `hidesOnDeactivate = true` — 点击外部 / Esc 自动关闭
- 重新打开时保留搜索文本（`SearchViewModel` 持续存在）
- Liquid Glass 材质：`GlassEffectContainer` 封装 `.glassEffect(.regular, in: .rect(cornerRadius: 24))`

### 6.3 Apple Intelligence 光晕

- `IntelligenceGlow` — AngularGradient (teal/violet/coral/amber) 旋转 1.8s，60fps on M4+
- `GlassEffectContainer` 将 material 和 glow overlay 组合，`.allowsHitTesting(false)` 确保光晕不挡交互
- `@Environment(\.accessibilityReduceMotion)` → 静态渐变边框（无旋转和透明度脉冲）
- 4 层叠加动画

### 6.4 全局热键

- `GlobalHotkey` — 默认 `⌃⌘K`，支持 `KeyCombination` 类型配置
- Carbon `RegisterEventHotKey` 优先，CGEventTap fallback
- 需 Accessibility 权限，`HotkeyPermissionHelper` 引导授权流程
- 热键冲突检测和重试退避

### 6.5 其他 GUI 组件

- `SearchBarView` — 搜索输入框，自动补全支持
- `ResultsListView` — 可滚动结果容器，键盘导航
- `ResultRowView` — 单行结果（文件名/路径/大小/日期）
- `QuickLookPreview` — Space 快速预览
- `ResultContextMenu` — 右键菜单（Finder 中显示/复制路径）
- `ResultDragView` — 文件拖拽支持
- `SettingsView` / `SettingsWindow` — 偏好设置面板（排除路径、索引统计、重建）
- `SearchViewModel` — `@ObservableObject`，桥接 GUI 与 `IPCClientProtocol`
- `WorkspaceProtocol` — NSWorkspace 抽象协议（测试性）

---

## 7. 安全

| 措施 | 说明 |
|------|------|
| 文件权限 | ~/.deep-finder/ 目录 700，文件 600 |
| 隐私排除 | 默认不索引 Caches/Cookies/Keychains |
| 用户范围 | 只索引当前用户 home + 系统共享目录 |
| 分发 | GitHub Releases + Homebrew formula |
| 公证 | Apple Developer Program 签名 + notarytool |
| AI API Key | Keychain 存储（v3.0） |
| AI 网络传输 | 强制 HTTPS/TLS 1.3（v3.0） |
| AI 元数据脱敏 | 默认开启（v3.0） |
| AI 默认关闭 | 所有 AI 功能默认关闭（v3.0） |

---

## 8. 项目结构

**Single-library architecture.** Sources/ holds all modules (Index, Search, FS, Persist, Daemon, CLI, GUI, AI, Media, Services) under one monolithic `DeepFinder` library target. Two thin executables (`DeepFinderCLI`, `DeepFinderDaemon`) each contain only a `main.swift` and link the shared library. A single `DeepFinderTests` target covers all modules. This avoids cross-target dependency management while keeping build simple. Splitting into sub-libraries is planned to improve build parallelism and enforce module boundaries (see CLAUDE.md).

```
deep-finder/
├── Package.swift
├── Sources/
│   ├── Index/                    # FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex, ProductConfig
│   ├── Search/                   # SearchProvider, SearchCoordinator, FilterPipeline, SearchSorter, ContentScanner, AutocompleteProvider, DuplicateFinder, SearchBookmark, QueryTerm, PatternMatcher, ContentSearchProvider, FileHasher, FileIndexProvider, SearchFilter, SearchTypes
│   ├── FS/                       # FileScanner, FSEventWatcher, FileSystemEventStream, FSEventStreamImpl, MockEventStream, VolumeManager
│   ├── Persist/                  # IndexPersistence, IndexRecovery, PathEncryption
│   ├── Daemon/                   # DaemonMain, IPCServer, IPCClient, IPCProtocol, IPCFraming, ConfigStore, LaunchAgent
│   ├── CLI/                      # CLIMain, ArgParser, SingleShot, REPL, REPLCommands, REPLHistory, TerminalFormatter, ConfigCommands, DaemonCommands, InstallCommands, FuzzyCorrection, ServeMode, IPCClientProtocol, CLIOutputWriter
│   ├── GUI/                      # SearchPanelView, SearchBarView, ResultsListView, SearchViewModel, AppDelegate, GlobalHotkey, IntelligenceGlow, StatusBarController (v2.0+)
│   ├── AI/                       # AIConfig, AIContext, AIModelProvider, AnthropicProvider, CloudEmbeddingProvider, CrossLanguageSearch, DeepSeekProvider, EmbeddingProvider, FileMetadataSummary, GeminiProvider, HTTPClient, ImageSimilaritySearch, KeychainStore, LocalSpeechProvider, LocalVisionProvider, MatchExplainer, NLEmbeddingProvider, NLOperations, NLSearchTranslator, OpenAICompatibleProvider, PromptLoader, ProviderRegistry, QwenProvider, ResultSummarizer, SearchAdvisor, SemanticGrouper, SpeechAuthorization, VectorStore, VisionTaggingCoordinator
│   ├── Media/                    # ImageMetadataExtractor, AudioMetadataExtractor, VideoMetadataExtractor, PDFMetadataExtractor, MediaMetadataIndex
│   ├── Services/                 # HTTPSearchService, URLSchemeHandler, SearchIntent, SearchScriptCommand
│   ├── CLIEntry/                 # Thin executable entry point: main.swift → CLIMain
│   ├── DaemonEntry/              # Thin executable entry point: main.swift → DaemonMain
│   └── AppEntry/                 # GUI app entry point: main.swift → AppDelegate (v2.0+)
├── Tests/
│   ├── IndexTests/
│   ├── SearchTests/
│   ├── FSTests/
│   ├── PersistTests/
│   ├── DaemonTests/
│   ├── CLITests/
│   ├── GUITests/
│   ├── AITests/
│   ├── MediaTests/
│   └── ServicesTests/
├── docs/superpowers/specs/       # Design doc + requirement files
├── VERSION
└── README.md
```

### Package.swift

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "deep-finder",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DeepFinder", targets: ["DeepFinder"]),
        .executable(name: "deepfinder", targets: ["DeepFinderCLI"]),
        .executable(name: "deepfinder-daemon", targets: ["DeepFinderDaemon"]),
    ],
    targets: [
        .target(
            name: "DeepFinder",
            path: "Sources",
            exclude: ["CLIEntry", "DaemonEntry"],
            linkerSettings: [
                .linkedLibrary("edit")
            ]
        ),
        .executableTarget(
            name: "DeepFinderCLI",
            dependencies: ["DeepFinder"],
            path: "Sources/CLIEntry"
        ),
        .executableTarget(
            name: "DeepFinderDaemon",
            dependencies: ["DeepFinder"],
            path: "Sources/DaemonEntry"
        ),
        .testTarget(
            name: "DeepFinderTests",
            dependencies: ["DeepFinder"],
            path: "Tests"
        ),
    ]
)
```

**Build products:**
- `DeepFinder` (library) — all modules, linked by CLI and daemon
- `deepfinder` (executable) — thin `CLIEntry/main.swift` calling `CLIMain`
- `deepfinder-daemon` (executable) — thin `DaemonEntry/main.swift` calling `DaemonMain`

**Dependency direction (one-way, no cycles):**
```
CLI/Daemon → Search → Index
  └→ IPC
(v2.0: GUI → IPC → Daemon, same daemon binary)
```

Index layer has zero UI/CLI dependencies and can be tested in isolation.

---

## 9. 性能基准（M4+ 目标）

| 指标 | 目标 | 测试方法 |
|------|------|----------|
| 索引构建 (100k 文件) | < 3s | 合成 FileRecord 数组 |
| 索引构建 (1M 文件) | < 10s | 合成 FileRecord 数组 |
| 前缀查询 (Trie) | < 2ms (p99) | 1M-record, 10k 查询 |
| 子串查询 (FullSubstringMap) | < 1ms (p99) | 1M-record, 10k 查询 |
| 拼音查询 | < 15ms (p99) | 1M-record, 10k 查询 |
| 启动加载 (1M 文件) | < 1s | SQLite → 内存重建 |
| 内存 (1M 文件) | < 10GB | 全子串映射，速度优先 |
| 增量更新 (100 events) | < 10ms | 热索引批量插入/删除 |
| IPC round-trip | < 1ms | 单次 query → response |
| CLI 首次结果 | < 5ms | daemon 已运行时 |

---

## 10. 实现顺序（v0.1 — v1.0）

| Phase | 版本 | 内容 | 依赖 |
|-------|------|------|------|
| 1 | v0.1 | FileRecord → Trie → FullSubstringMap → TrigramIndex → PinyinIndex → InMemoryIndex → Fixtures + Tests | 无 |
| 2 | v0.2 | FileSystemEventStream → FileScanner → FSEventWatcher → IndexPersistence → IndexRecovery | Phase 1 |
| 3 | v0.3 | SearchProvider 协议 → SearchCoordinator (plain actor) → Performance benchmarks | Phase 2 |
| 4 | v0.4 | DaemonMain → IPCServer → IPCProtocol → Unix socket → PID → LaunchAgent → Signal handling | Phase 3 |
| 5 | v0.5 | CLIMain → ArgParser → SingleShot → IPCClient → TerminalFormatter (ANSI) | Phase 4 |
| 6 | v0.6 | REPL (readline) → REPLCommands → History → Completion | Phase 5 |
| 7 | v0.7 | Daemon 管理 (start/stop/install) → Config 管理 → man page → shell completions | Phase 6 |
| 8 | v1.0 | 集成测试 → Homebrew formula → 打磨 → release | Phase 7 |
