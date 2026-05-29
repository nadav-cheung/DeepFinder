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
| 应用形态 | v1.0 CLI（daemon + REPL + single-shot），v2.0 加 GUI（Menu Bar App） |
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
enum AICapability: Sendable {
    case textToSearch       // 自然语言 → 搜索语法
    case resultSummary      // 结果摘要 & 分类
    case querySuggestion    // AI 搜索建议
    case intentAnalysis     // 意图理解
    case localVision        // 本地图片理解（CoreML）
    case localSpeech        // 本地语音识别（Speech）
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

/// AI 模型提供者协议（基础）
protocol AIModelProvider: Sendable {
    var name: String { get }
    var capabilities: Set<AICapability> { get }
}

/// 文本补全能力（DeepSeek/Qwen 实现）
protocol AITextCompletion: AIModelProvider {
    func complete(
        prompt: String,
        context: AIContext
    ) -> AsyncThrowingStream<String, Error>
}

/// 自然语言翻译为搜索语法（DeepSeek/Qwen 实现）
protocol AISearchTranslator: AIModelProvider {
    func translateToSearchSyntax(
        naturalLanguage: String
    ) async throws -> String
}

/// 图片理解能力（LocalVisionProvider 实现）
protocol AIVisionProvider: AIModelProvider {
    func analyzeImage(at path: String) async throws -> [String]
}

/// 语音识别能力（LocalSpeechProvider 实现）
protocol AISpeechProvider: AIModelProvider {
    func transcribe(audioAt path: String) async throws -> String
}
```

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
│  │              IndexingEngine (actor)                   │   │
│  │  ┌──────────────┐  ┌────────────────────────────┐   │   │
│  │  │  FileScanner │  │ FileSystemEventStream      │   │   │
│  │  └──────┬───────┘  └───────────┬────────────────┘   │   │
│  │         │                      │                     │   │
│  │  ┌──────▼──────────────────────▼───────────────┐    │   │
│  │  │     InMemoryIndex (actor)                    │    │   │
│  │  │  - Trie (前缀匹配)                           │    │   │
│  │  │  - FullSubstringMap (子串 O(1) 直查)         │    │   │
│  │  │  - TrigramIndex (长文件名兜底)               │    │   │
│  │  │  - PinyinIndex (拼音搜索)                    │    │   │
│  │  │  - FileRecord[] (路径、大小、日期)           │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                      │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │  IndexPersistence (SQLite WAL)                │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
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

| 模块 | 职责 | Target |
|------|------|--------|
| **DeepFinderIndex** | 共享库：Index + Search + FS + Persist | library |
| **DaemonMain** | Daemon 入口：加载索引 → bind socket → 运行循环 | executable |
| **IPCServer** | Unix socket accept loop + JSON 请求分发 | executable |
| **IPCProtocol** | IPC 消息 Codable 类型（共享） | executable |
| **IPCClient** | CLI 端连接 daemon socket | executable |
| **CLIMain** | CLI 入口：参数解析 → 模式选择 | executable |
| **SingleShot** | 单次查询模式 | executable |
| **REPL** | 交互循环：readline + 命令分发 | executable |
| **TerminalFormatter** | ANSI 颜色、列布局、匹配高亮 | executable |
| **ArgParser** | 手动 CommandLine.arguments 解析 | executable |

### 依赖方向

```
DeepFinderCLI ──depends on──→ DeepFinderIndex (shared types only)
DeepFinderDaemon ──depends on──→ DeepFinderIndex (full dependency)
IPCProtocol types shared between CLI and Daemon via DeepFinderIndex
```

依赖单向向下，无循环。Index 层不依赖 CLI/Daemon，可独立测试。

### 并发模型

```
InMemoryIndex: actor
  - 所有读/写操作通过 actor isolation 保证线程安全
  - 快照读 API: snapshot() -> IndexSnapshot (不可变)

IndexingEngine: actor
  - 协调 FileScanner 和 FSEventWatcher
  - 通过 InMemoryIndex actor 方法写入

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

```swift
protocol SearchProvider: Sendable {
    associatedtype SearchStream: AsyncSequence where SearchStream.Element == SearchResult

    var name: String { get }
    var isReady: Bool { get }

    func search(query: SearchQuery) -> SearchStream
    func cancel(queryID: String)
    func prepare() async
}

struct SearchQuery: Sendable {
    let id: String
    let text: String           // NFC + lowercased
    let limit: Int             // 默认 100
    let options: SearchOptions
}

struct SearchResult: Sendable {
    let record: FileRecord
    let provider: String
    let score: Double
    let matchType: MatchType
}

enum MatchType: Sendable {
    case exact
    case prefix
    case substring
    case pinyin
    case regex       // future
    case semantic    // future
}
```

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
3. 启动 IndexingEngine（FSEventWatcher + 后台验证）
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

```swift
// MARK: - Requests

struct IPCRequest: Codable {
    let id: String          // UUID, 匹配 response
    let payload: IPCRequestPayload
}

enum IPCRequestPayload: Codable {
    case query(IPCQueryRequest)
    case status
    case configGet(key: String)
    case configSet(key: String, value: String)
    case indexRebuild
    case daemonStop
}

struct IPCQueryRequest: Codable {
    let text: String
    let limit: Int          // 默认 100
    let offset: Int         // 默认 0
    let sortBy: IPSearchSort?
    let fileType: IPCFileType?  // file / folder / nil(both)
}

enum IPSearchSort: String, Codable {
    case name, size, date, ext
}

enum IPCFileType: String, Codable {
    case file, folder
}

// MARK: - Responses

struct IPCResponse: Codable {
    let id: String          // 匹配 request id
    let payload: IPCResponsePayload
}

enum IPCResponsePayload: Codable {
    case queryResults(IPCQueryResponse)
    case status(IPCStatusResponse)
    case configValue(key: String, value: String?)
    case ack
    case error(IPCError)
}

struct IPCQueryResponse: Codable {
    let totalResults: Int
    let results: [IPCSearchResult]
    let hasMore: Bool
}

struct IPCSearchResult: Codable {
    let rank: Int           // 1-based
    let name: String        // originalName
    let path: String
    let parentPath: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date
    let `extension`: String?
    let matchRange: Range<String.Index>?  // 匹配范围，用于 CLI 高亮
}

struct IPCStatusResponse: Codable {
    let state: String       // "stale" / "verifying" / "live" / "error"
    let indexedFiles: Int
    let uptime: TimeInterval
    let memoryUsage: Int64  // bytes
    let daemonPID: Int32
}

struct IPCError: Codable {
    let code: Int
    let message: String
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

## 6. v2.0 GUI 层（deferred）

以下设计 deferred 到 v2.0。daemon 和 IPC 不变，GUI 作为新的 IPC client。

### 6.1 窗口

- NSPanel 浮动窗口，无标题栏
- Liquid Glass 材质：`.glassEffect(.regular, in: .rect(cornerRadius: 24))`
- `.floating` 窗口层级
- 点击外部 / Esc 自动关闭
- 屏幕顶部居中

### 6.2 Apple Intelligence 光晕

- AngularGradient (teal/violet/coral/amber) 旋转 ~1.8s
- 4 层叠加，60fps on M4+
- `accessibilityReduceMotion` → 静态渐变边框
- 面板隐藏时暂停动画

### 6.3 全局热键

- 默认 `⌃⌘K`，可配置
- Carbon RegisterEventHotKey 优先，CGEventTap fallback
- 需 Accessibility 权限

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

```
deep-finder/
├── Package.swift
├── Sources/
│   ├── DeepFinderIndex/               # 共享库 (library target)
│   │   ├── Index/
│   │   │   ├── FileRecord.swift
│   │   │   ├── Trie.swift
│   │   │   ├── FullSubstringMap.swift
│   │   │   ├── TrigramIndex.swift
│   │   │   ├── PinyinIndex.swift
│   │   │   ├── InMemoryIndex.swift
│   │   │   └── IndexingEngine.swift
│   │   ├── Search/
│   │   │   ├── SearchProvider.swift
│   │   │   ├── SearchCoordinator.swift
│   │   │   ├── SearchQuery.swift
│   │   │   └── SearchResult.swift
│   │   ├── FS/
│   │   │   ├── FileSystemEventStream.swift
│   │   │   ├── FileScanner.swift
│   │   │   └── FSEventWatcher.swift
│   │   ├── Persist/
│   │   │   ├── IndexPersistence.swift
│   │   │   └── ConfigStore.swift
│   │   └── IPC/
│   │       └── IPCProtocol.swift       # 共享消息类型
│   ├── DeepFinderDaemon/              # Daemon 可执行文件 (executable target)
│   │   ├── DaemonMain.swift
│   │   ├── IPCServer.swift
│   │   └── DaemonConfig.swift          # LaunchAgent plist, PID 管理
│   └── DeepFinderCLI/                 # CLI 可执行文件 (executable target)
│       ├── CLIMain.swift
│       ├── ArgParser.swift
│       ├── SingleShot.swift
│       ├── REPL.swift
│       ├── REPLCommands.swift
│       ├── TerminalFormatter.swift
│       ├── IPCClient.swift
│       ├── History.swift
│       └── Completion.swift
├── Tests/
│   ├── IndexTests/
│   │   ├── FileRecordTests.swift
│   │   ├── TrieTests.swift
│   │   ├── FullSubstringMapTests.swift
│   │   ├── TrigramIndexTests.swift
│   │   ├── PinyinIndexTests.swift
│   │   ├── InMemoryIndexTests.swift
│   │   └── InMemoryIndexPerformanceTests.swift
│   ├── SearchTests/
│   │   ├── SearchCoordinatorTests.swift
│   │   └── SearchProviderContractTests.swift
│   ├── FSTests/
│   │   ├── FileScannerTests.swift
│   │   ├── FSEventWatcherTests.swift
│   │   └── IndexPersistenceTests.swift
│   ├── DaemonTests/
│   │   ├── IPCProtocolTests.swift
│   │   └── DaemonLifecycleTests.swift
│   ├── CLITests/
│   │   ├── SingleShotTests.swift
│   │   ├── REPLCommandTests.swift
│   │   ├── TerminalFormatterTests.swift
│   │   └── ArgParserTests.swift
│   └── Fixtures/
│       ├── FileRecordGenerator.swift
│       ├── EdgeCaseFixtures.swift
│       └── PerformanceFixtures.swift
├── docs/
│   └── superpowers/specs/
│       ├── requirements.md          # index file → reqs/
│       ├── reqs/                    # per-module requirement files
│       │   ├── 00-overview.md
│       │   ├── v0.1-index-core.md
│       │   ├── v0.2-file-system.md
│       │   ├── v0.3-search.md
│       │   ├── v0.4-daemon-ipc.md
│       │   ├── v0.5-cli-singleshot.md
│       │   ├── v0.6-repl.md
│       │   ├── v0.7-daemon-mgmt.md
│       │   ├── v1.0-cli-release.md
│       │   ├── v1.1-advanced-syntax.md
│       │   ├── v1.2-metadata-filter.md
│       │   ├── v1.3-search-exp.md
│       │   ├── v1.4-content-search.md
│       │   ├── v1.5-duplicate.md
│       │   ├── v2.0-gui.md
│       │   ├── v3.0-ai.md
│       │   └── v3.1-rag.md
│       └── 2026-05-26-deep-finder-design.md
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
        .library(name: "DeepFinderIndex", targets: ["DeepFinderIndex"]),
        .executableProduct(name: "deepfinder", targets: ["DeepFinderCLI"]),
        .executableProduct(name: "deepfinder-daemon", targets: ["DeepFinderDaemon"]),
    ],
    targets: [
        .target(
            name: "DeepFinderIndex",
            path: "Sources/DeepFinderIndex"
        ),
        .executableTarget(
            name: "DeepFinderDaemon",
            dependencies: ["DeepFinderIndex"],
            path: "Sources/DeepFinderDaemon"
        ),
        .executableTarget(
            name: "DeepFinderCLI",
            dependencies: ["DeepFinderIndex"],
            path: "Sources/DeepFinderCLI"
        ),
        .testTarget(
            name: "DeepFinderIndexTests",
            dependencies: ["DeepFinderIndex"],
            path: "Tests/IndexTests"
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["DeepFinderIndex"],
            path: "Tests/SearchTests"
        ),
        .testTarget(
            name: "FSTests",
            dependencies: ["DeepFinderIndex"],
            path: "Tests/FSTests"
        ),
        .testTarget(
            name: "DaemonTests",
            dependencies: ["DeepFinderDaemon"],
            path: "Tests/DaemonTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["DeepFinderCLI"],
            path: "Tests/CLITests"
        ),
    ]
)
```

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
