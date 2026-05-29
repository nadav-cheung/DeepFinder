# Everything Search - macOS Design Spec

对标 Windows Everything 的 macOS 极速文件搜索工具。

## 项目概要

| 项目 | 值 |
|------|-----|
| 名称 | everything-search |
| 平台 | macOS only, Apple Silicon M4+ |
| 最低系统 | macOS 26 (Tahoe) |
| 架构 | arm64 only |
| 技术栈 | Swift + SwiftUI |
| 应用形态 | Menu Bar App (LSUIElement=true) |
| 开源 | 是 |
| 数据目录 | ~/.everything-search/ |
| 分发渠道 | GitHub Releases + Homebrew Cask |

## 功能路线图

对标 Windows Everything 全部功能，采用渐进式开发。每个版本独立可用，逐步叠加能力。

**设计原则**：性能优先，内存/CPU 不受约束。SearchProvider 协议 + 插件式架构确保新功能不影响现有代码。

### v1.0 — 核心搜索

| 功能 | 说明 |
|------|------|
| 文件名搜索 | 前缀 + 任意子串 + 拼音（FullSubstringMap O(1)) |
| 实时监控 | FSEvents 增量更新 |
| 全局热键 | ⌥Space 唤起，Esc 关闭 |
| Menu Bar App | LSUIElement=true，无 Dock 图标 |
| Spotlight 风格 UI | Liquid Glass + Apple Intelligence 光晕 |
| 持久化索引 | SQLite WAL，启动重建 <2s |
| 拼音搜索 | CFStringTokenizer → 拼音 Trie，支持首字母缩写 |
| NFC 统一化 | 所有文件名 NFC 统一化，避免 Unicode 比较问题 |

### v1.1 — 高级搜索语法

对标 Everything 搜索语法。

| 功能 | 示例 | 说明 |
|------|------|------|
| 布尔运算符 | `ABC 123` (AND), `ABC\|123` (OR), `!ABC` (NOT) | 空格=AND, \|=OR, !=NOT |
| 通配符 | `*.pdf`, `report_??.xlsx` | `*` 任意字符, `?` 单字符 |
| 正则表达式 | `regex:^report_\d{4}` | regex: 前缀激活 |
| 路径限定 | `Documents\ report`, `parent:~/Documents` | 路径内搜索 |
| 修饰符 | `case:`, `file:`, `folder:`, `ext:pdf;doc`, `path:` | 搜索选项控制 |
| 搜索历史 | ↑↓ 回溯历史查询 | 持久化最近 100 条 |

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
| 高级搜索面板 | GUI 表单构建复杂查询 | 对标 Everything Advanced Search |

### v1.3 — 搜索体验

对标 Everything 书签、过滤器、排序。

| 功能 | 说明 |
|------|------|
| 书签 | 保存搜索+排序+过滤，一键恢复 |
| 自定义过滤器 | 预定义搜索条件 + 快捷键 + 宏（如 `photos:` → `ext:jpg;png;heic pic:`）|
| 结果排序 | 名称/大小/日期/扩展名/路径，自然排序（natural sort）|
| 排序持久化 | 记住上次排序方式 |
| Quick Look | Space 预览文件 |
| 右键菜单 | 在 Finder 中显示 / 复制路径 / 拖拽 / 打开方式 |
| 搜索建议 | 基于历史和热门文件的自动补全 |
| 高亮匹配 | 结果中高亮匹配的子串，保留原始大小写 |

### v1.4 — 内容搜索

对标 Everything content: 函数。

| 功能 | 示例 | 说明 |
|------|------|------|
| 内容搜索 | `*.eml dm:thisweek content:banana` | 流式读取，结合其他过滤先缩小范围 |
| 编码支持 | UTF-8, UTF-16, UTF-16BE | 自动检测或手动指定 |
| 文件类型限定 | `ext:swift;py;md content:TODO` | 只搜索特定扩展名的内容 |
| 行号定位 | 结果显示匹配行号，点击跳转编辑器 | 仅文本文件 |

**注意**：内容不预建索引（对标 Everything 设计），查询时实时扫描，需结合其他过滤缩小范围。

### v1.5 — 重复文件与高级查找

对标 Everything dupe: 系列函数。

| 功能 | 示例 | 说明 |
|------|------|------|
| 按名称查重 | `dupe:` | 相同文件名的文件 |
| 按大小查重 | `size:>1mb sizedupe:` | 相同大小的文件 |
| 按内容哈希查重 | `hashdupe:` | SHA-256，比 Everything 更精确 |
| 空文件夹 | `empty:` | 查找空目录 |
| 文件名长度 | `len:>100` | 超长文件名查找 |
| 子项计数 | `childcount:0`, `childfilecount:>10` | 目录内文件/子目录数量 |

### v2.0 — 扩展索引

对标 Everything File Lists + Folder Indexing + Index Journal。

| 功能 | 说明 |
|------|------|
| 外置卷索引 | USB/Thunderbolt 磁盘自动索引，卸载时保留索引，重新挂载增量更新 |
| 网络卷索引 | SMB/AFP/NFS 共享目录索引 |
| 虚拟文件夹索引 | 对标 1.5 新功能，索引非本地路径 |
| 离线文件列表 | 对标 File Lists — 光盘/归档媒体的离线索引 |
| Spotlight 元数据 | 通过 mdls 集成 Spotlight 元数据（尺寸、时长、标签等）|
| 索引日志 | 对标 Index Journal — 记录文件变更历史 |
| 排除规则 | 可配置的排除/包含路径和模式 |

### v2.1 — 媒体元数据

对标 Everything 图片/音频元数据搜索，macOS 通过 mdls + AVFoundation 实现。

| 功能 | 示例 | 说明 |
|------|------|------|
| 图片尺寸 | `width:>2560`, `dimensions:800x600..1920x1080` | EXIF 元数据 |
| 图片方向 | `orientation:landscape` | portrait/landscape |
| 音频标签 | `artist:周杰伦`, `album:范特西`, `genre:pop` | ID3/AAC 元数据 |
| 视频信息 | `duration:>300`, `codec:h264` | AVFoundation 元数据 |
| PDF 元数据 | `pdf-author:xxx`, `pdf-pages:>50` | PDFKit 提取 |

### v2.2 — 服务与集成

对标 Everything HTTP Server + ETP/FTP + CLI + SDK。

| 功能 | 说明 |
|------|------|
| HTTP 搜索服务 | 本地 Web 界面，浏览器搜索文件 |
| 命令行工具 | `es search "keyword"` — 终端搜索，输出 JSON/纯文本 |
| URL Scheme | `everything://search?q=keyword` — 其他 app 调起搜索 |
| Shortcuts 集成 | Apple Shortcuts 动作，支持自动化 |
| AppleScript | 脚本化搜索和结果获取 |
| Share Extension | 从其他 app 搜索文件 |

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
| 文件标签 | ✅ 本地 CoreML 分类（文档/代码/媒体推断） | ✅ 根据文件名/路径元数据推断语义标签 |
| 自然语言 → 搜索语法 | ✗ 需要 LLM 能力 | ✅ "找上周改过的大文件" → `dm:lastweek size:>10mb` |
| 结果摘要 | ✗ | ✅ 基于元数据（文件名/大小/日期）生成摘要 |
| 搜索建议 | ✗ | ✅ 基于结果元数据生成优化建议 |
| 语音搜索 | ✅ 本地 Speech 框架语音识别 | ✅ 文本送云端理解意图 |

#### AIProvider 协议设计

```swift
/// AI 能力定义
enum AICapability: Sendable {
    case textToSearch       // 自然语言 → 搜索语法
    case resultSummary      // 结果摘要 & 分类
    case querySuggestion    // 搜索建议
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
    // ✗ 无文件内容, ✗ 无缩略图, ✗ 无二进制数据
}

/// AI 上下文 — 发送给云端模型的全部信息
struct AIContext: Sendable {
    let query: String
    let resultMetadata: [FileMetadataSummary]
    let indexStats: IndexStats
}

/// AI 模型提供者协议
protocol AIModelProvider: Sendable {
    var name: String { get }
    var capabilities: Set<AICapability> { get }

    /// 流式返回 AI 响应
    func complete(
        prompt: String,
        context: AIContext
    ) -> AsyncThrowingStream<String, Error>

    /// 自然语言翻译为搜索语法
    func translateToSearchSyntax(
        naturalLanguage: String
    ) async throws -> String
}

// 云端实现
final class DeepSeekProvider: AIModelProvider { ... }
final class QwenProvider: AIModelProvider { ... }

// 本地实现（Vision + CoreML，零外传）
final class LocalVisionProvider: AIModelProvider { ... }
final class LocalSpeechProvider: AIModelProvider { ... }
```

#### 典型数据流

**场景 1：自然语言搜索**
```
用户: "找上周修改的超过100MB的视频文件"
  ├─ [云端] DeepSeek 翻译 → "ext:mp4;mov;mkv dm:lastweek size:>100mb"
  ├─ [本地] SearchCoordinator 执行搜索语法
  ├─ [本地] 结果元数据脱敏 → 发送到云端
  ├─ [云端] 可选：Qwen 生成结果摘要
  └─ [本地] UI 渲染
```

**场景 2：以图搜文件（全程零外传）**
```
用户: 想找类似某张照片的文件
  ├─ [本地] Vision 框架分析图片 → 标签 ["sunset", "beach", "ocean"]
  ├─ [本地] 标签存入 PinyinIndex/Trie
  ├─ [本地] 用标签搜索本地索引
  └─ [本地] 结果显示
```

**场景 3：搜索建议**
```
用户输入: "report"
  ├─ [本地] 即时文件名搜索 → 显示结果
  ├─ [云端] 异步：发送结果元数据 ["report_Q1.pdf", "report_Q2.xlsx"]
  │         DeepSeek 返回: "您可能在找季度报告，试试 ext:xlsx dm:thisyear"
  └─ [本地] UI 显示 AI 建议气泡
```

#### 用户隐私控制

```
Settings > AI 搜索
  ├── [开关] 启用 AI 辅助搜索（默认关闭）
  ├── [下拉] 文本模型: DeepSeek / Qwen / 关闭
  ├── [下拉] 视觉分析: 本地 CoreML / 关闭
  ├── [开关] 发送文件元数据到云端（默认关闭，需手动开启）
  ├── [开关] 路径脱敏（默认开启：/Users/nadav → ~/）
  ├── [开关] 本地图片标签生成（CoreML，默认开启）
  ├── [API Key] 用户自有 API Key（不存储到云端）
  └── [预览] "查看即将发送的数据" — 展示实际外传数据样例
```

#### 项目结构扩展

```
Sources/
├── AI/                          # v3.0 新增
│   ├── AIModelProvider.swift    # 协议定义
│   ├── AIContext.swift          # AIContext + FileMetadataSummary
│   ├── AICapability.swift       # 能力枚举
│   ├── DeepSeekProvider.swift   # DeepSeek API 实现
│   ├── QwenProvider.swift       # 千问 API 实现
│   ├── LocalVisionProvider.swift # Vision + CoreML 本地图片分析
│   ├── LocalSpeechProvider.swift # Speech 框架本地语音识别
│   └── AISearchCoordinator.swift # AI 搜索协调（翻译→执行→摘要）
```

### macOS 特有增强

Windows Everything 不具备，利用 macOS 平台能力：

| 功能 | 说明 |
|------|------|
| Finder 标签 | 搜索 macOS Finder Tags（红/橙/黄/绿/蓝/紫/灰）|
| Finder 评论 | 搜索 Spotlight Comments |
| iCloud 同步状态 | 区分本地/云端/仅云端文件 |
| APFS 快照 | 在 Time Machine 快照中搜索历史版本 |
| 沙盒友好 | 未来可选沙盒版本上架 App Store（功能受限） |
| Apple Watch | 手表上查找最近文件（Complication） |
| Widgets | 桌面/通知中心小组件显示搜索/最近文件 |
| Live Activity | 索引进度 Live Activity（锁屏/通知中心）|

---

## 1. 系统架构

```
┌─────────────────────────────────────────────────┐
│                   App Entry                      │
│              (Menu Bar + Hotkey)                  │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│              SearchPanel (SwiftUI)               │
│    ┌─ Apple Intelligence Glow Border ─┐         │
│    │  SearchBar → ResultsList          │         │
│    │  AI Suggestion Bubble (v3.0)      │         │
│    └───────────────────────────────────┘         │
└──────────────────────┬──────────────────────────┘
                       │ query string
┌──────────────────────▼──────────────────────────┐
│              SearchCoordinator                    │
│  - 分发查询给 SearchProvider                      │
│  - 合并 & 排序结果                                │
└──────┬───────────────┬───────────────┬──────────┘
       │               │               │
┌──────▼──────┐  ┌─────▼───────┐  ┌────▼──────────────┐
│ FileIndex   │  │  Spotlight  │  │  AISearchCoord     │
│  Provider   │  │   Provider  │  │  (v3.0)            │
│ (自建索引)   │  │  (mdfind)   │  │  ┌──────────────┐  │
└──────┬──────┘  └─────────────┘  │  │ Local Engine │  │
       │                          │  │ CoreML/Vision│  │
       │                          │  └──────┬───────┘  │
       │                          │  ┌──────▼───────┐  │
       │                          │  │Cloud Models  │  │
       │                          │  │DeepSeek/Qwen │  │
       │                          │  └──────────────┘  │
       │                          └───────────────────┘
       │                                   │
       │            只发送元数据，不发送文件内容  │
       │                          ┌────────▼──────────┐
       │                          │  Privacy Boundary  │
       │                          └───────────────────┘
┌──────▼──────────────────────────────────────────┐
│              IndexingEngine (actor)              │
│  ┌──────────────┐  ┌────────────────────────┐  │
│  │  FileScanner │  │ FileSystemEventStream  │  │
│  │  (全量扫描)   │  │  (FSEvents 抽象层)      │  │
│  └──────┬───────┘  └───────────┬────────────┘  │
│         │                      │                │
│  ┌──────▼──────────────────────▼────────────┐  │
│  │     InMemoryIndex (actor)                 │  │
│  │  - Trie (前缀匹配)                        │  │
│  │  - FullSubstringMap (子串 O(1) 直查)      │  │
│  │  - TrigramIndex (长文件名兜底)            │  │
│  │  - PinyinIndex (拼音搜索)                 │  │
│  │  - FileRecord[] (路径、大小、日期)        │  │
│  └──────────────────────────────────────────┘  │
│                                                 │
│  ┌──────────────────────────────────────────┐  │
│  │  IndexPersistence (SQLite WAL)            │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### 模块职责

| 模块 | 职责 |
|------|------|
| SearchPanel | SwiftUI 浮动窗口，Spotlight 风格 UI + Apple Intelligence 光晕 + AI 建议气泡 |
| SearchCoordinator | 查询分发、流式结果合并排序 |
| SearchProvider (协议) | 统一搜索接口，返回 AsyncSequence |
| FileIndexProvider | MVP 唯一的 Provider，调用自建索引 |
| AISearchCoordinator | v3.0 — AI 辅助搜索协调，管理本地/云端 AIProvider |
| AIModelProvider (协议) | v3.0 — AI 模型统一接口（DeepSeek/Qwen/本地 CoreML） |
| IndexingEngine (actor) | 文件扫描 + FSEvents 监听 → 维护内存索引 |
| InMemoryIndex (actor) | Trie + FullSubstringMap + TrigramIndex + PinyinIndex，纯内存 |
| IndexPersistence | SQLite WAL 存储 FileRecord[]，内存重建索引 |

### 依赖方向

```
App → UI → Search → Index
  └→ Hotkey
```

依赖单向向下，无循环。Index 层不依赖 UI，可独立测试。

### 并发模型

```
InMemoryIndex: actor
  - 所有读/写操作通过 actor isolation 保证线程安全
  - 快照读 API: snapshot() -> IndexSnapshot (不可变，供 SearchCoordinator 消费)

IndexingEngine: actor
  - 协调 FileScanner 和 FSEventWatcher
  - 通过 InMemoryIndex actor 方法写入

SearchCoordinator: @MainActor
  - UI 层，在主线程消费结果
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
         └──────────┘
```

UI 可根据 `indexState` 显示状态：stale 时提示"结果可能不完整"，verifying 时显示进度，live 时无提示。

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

// 用于排序的辅助数据，存储在 SQLite side table
struct UsageStats {
    let openCount: Int
    let lastOpenedAt: Date?
}
// UsageStats 随 FileRecord 一起持久化到 SQLite（独立 side table，按 fileRecordID 关联）
```

所有文件名入库前做 **NFC 统一化**（`name.precomposedStringWithCanonicalMapping`），查询时同样统一化。

**大小写处理**：默认不区分大小写（APFS 默认行为）。FullSubstringMap 的 key 统一用 `.lowercased()` 存储，查询时同样 `.lowercased()`。显示时使用 `originalName` 保留原始大小写。

### 2.2 索引结构（速度优先）

| 索引 | 结构 | 用途 | 查询速度 | 内存/文件 |
|------|------|------|----------|-----------|
| Trie | Unicode scalar 字典树 | 前缀匹配、即时补全 | O(k) | O(n) |
| FullSubstringMap | 子串 → [FileRecord.ID] 直接映射 | 任意子串 O(1) 命中 | O(1) | O(n²) |
| TrigramIndex | trigram → [FileRecord.ID] posting list | 长文件名(>64字符)子串匹配 | O(1) → 交集 → 验证 | O(n) |

**设计原则：速度第一，内存不是瓶颈。**

- 文件名 ≤64 字符：建 **全子串映射**（所有子串直接指向 FileRecord.ID），查询 O(1) 零计算
- 文件名 >64 字符：退化为 trigram + 交集验证（长文件名极少见）
- M4+ 统一内存架构，1M 文件的全子串映射约占 2-4GB（取决于子串去重策略），可接受。需实际 benchmark 验证

**FullSubstringMap 工作原理：**

```
文件名 "report.pdf" (11 chars) 的所有子串:
"r", "re", "rep", ..., "report.pdf", "e", "ep", ..., "df"
每个子串 → 直接映射到 FileRecord.ID

查询 "port": 直接查 HashMap["port"] → 结果
无需交集计算，无需验证，零延迟
```

**TrigramIndex 退化为长文件名兜底：**

```
文件名 "very-long-filename..." (>64 chars) → trigram 分词
"ver", "ery", ... → 各 trigram 映射到 FileRecord.ID
查询时取交集 + 精确验证
```

**为什么不取 ReverseTrie：** 全子串映射已覆盖所有前缀/后缀/子串场景，无需额外结构。

**拼音索引（中文用户强需求）：**

```
文件名 "季度报告.pdf" → CFStringTokenizer 提取拼音:
"ji", "du", "bao", "gao"

用户输入 "baogao" → 拼音索引命中 → 返回 "季度报告.pdf"
用户输入 "jdbg"   → 拼音首字母索引命中 → 同样返回
```

PinyinIndex 单独一个 Trie，存储拼音 token → FileRecord.ID 映射。

### 2.3 全量扫描

- `FileManager.enumerator(at:rootURL, ...)` 遍历所有卷
- 跳过：`/System`, `/Library`, `.Trash`, `.git`, `node_modules`, `.Spotlight-V100`，可配置
- 默认排除隐私目录：`~/Library/Caches`, `~/Library/Cookies`, `~/Library/Keychains`
- 只索引当前用户 home 目录 + 系统共享目录（不索引其他用户 home）
- **外置磁盘/网络卷**：全部索引。卷卸载时从索引移除，重新挂载时增量更新
- `TaskGroup` 按卷并行扫描
- 边扫边建索引：扫描过程中即可搜索，不等全部完成
- 全量扫描使用 `TaskGroup` 配合 `.userInitiated` 优先级（与项目 Swift Concurrency 模型一致）

### 2.4 FSEvents 增量更新

**抽象层设计：**

```swift
protocol FileSystemEventStream: Sendable {
    func start(paths: [String], handler: @escaping @Sendable ([(String, FSEventStreamEventFlags)]) -> Void)
    func stop()
    var isRunning: Bool { get }
}

// 生产实现：包装 FSEventStreamCreate
final class FSEventStreamImpl: FileSystemEventStream { ... }

// 测试实现：可编程注入事件
final class MockEventStream: FileSystemEventStream { ... }
```

| 事件 | 操作 |
|------|------|
| 文件创建 | 插入索引 |
| 文件删除 | 移除索引 |
| 文件重命名 | 删除旧记录 + 插入新记录 |
| 文件修改 | 更新元数据（大小、日期） |

**启动衔接流程（解决 stale gap）：**

```
1. 加载持久化索引 → 立即可搜索（indexState = .stale）
2. 立即启动 FSEventStream（捕获加载后的变更）
3. 如果有保存的 cursor → getHistoricalEvents 补齐差距
   - cursor 失效（系统已清理）→ 触发全量重建
   - getHistoricalEvents 失败 → 触发全量重建
4. 后台全量验证扫描（indexState = .verifying）
5. 验证完成 → indexState = .live
```

### 2.5 持久化

```
~/.everything-search/
├── index.db          # SQLite WAL 模式
├── config.json       # 用户配置
└── log/              # 运行日志
```

**权限**：目录 700，文件 600。防止其他用户读取文件路径。

**持久化策略 — SQLite 混合方案：**

- SQLite 存储 `FileRecord[]`（简单表：id, name, path, metadata 列）
- 不持久化索引结构（Trie / FullSubstringMap / TrigramIndex / PinyinIndex）→ 启动时从 FileRecord[] 重建。英文文件名场景 M4 上 ~1-2s；大量中文文件名场景 PinyinIndex 重建需额外 CFStringTokenizer 处理，预估 ~3-5s
- 增量持久化：内存缓冲变更，每 5 秒或每 100 条变更批量写入（避免 FSEvents 高频回调导致 I/O 抖动）
- WAL 模式：读写不互斥
- 索引损坏恢复：加载时校验（行数 + checksum），失败则删除重建 + 进度 UI

**M4+ 性能预估**：启动加载 < 1s，索引重建 < 2s。

---

## 3. SearchProvider 协议 & 搜索流程

### 3.1 协议（流式，支持未来异步/慢查询场景）

```swift
protocol SearchProvider: Sendable {
    associatedtype SearchStream: AsyncSequence where SearchStream.Element == SearchResult

    var name: String { get }
    var isReady: Bool { get }

    /// 流式搜索，支持增量返回结果。
    /// MVP 的内存索引可一次 yield 全部结果。
    /// 未来的 AI/内容搜索可增量 yield。
    func search(query: SearchQuery) -> SearchStream

    /// 取消进行中的查询
    /// 用于 Provider 内部资源清理（如取消网络请求、关闭文件句柄）。
    /// 与 Task cooperative cancellation 互补：Task.cancel() 停止消费 AsyncSequence，
    /// cancel(queryID:) 停止 Provider 内部生产。
    func cancel(queryID: String)

    /// Provider 初始化/预热
    func prepare() async
}

struct SearchQuery: Sendable {
    let id: String             // 唯一查询 ID，用于取消
    let text: String           // 已 NFC 统一化 + lowercased
    let limit: Int             // 默认 100
    let options: SearchOptions
}

struct SearchOptions: Sendable {
    var caseSensitive: Bool = false        // 默认不区分大小写
    var searchScope: SearchScope = .all    // 搜索范围

    enum SearchScope: Sendable {
        case all                    // 全局搜索
        case directories([String])  // 指定目录
    }
}

struct SearchResult: Sendable {
    let record: FileRecord
    let provider: String
    let score: Double          // 0.0 - 1.0
    let matchType: MatchType
}

enum MatchType: Sendable {
    case exact
    case prefix
    case substring
    case pinyin                // 拼音匹配
    case regex                 // future
    case semantic              // future
}
```

### 3.2 SearchCoordinator 流程

```
用户输入 → 构建 SearchQuery (NFC 统一化) → 遍历 ready Providers → 消费 AsyncSequence → 合并结果 → 排序 → 渲染
```

**防抖策略**：FileIndexProvider（内存索引）不需要防抖，每按键直接查询，零延迟。未来 mdfind/AI Provider 各自配置防抖时间。

**分页加载**：默认返回前 100 条结果。结果列表底部显示"还有 N 个结果"按钮，点击加载下一批 100 条。虚拟化列表（LazyVStack）保证滚动性能。

### 3.3 排序策略

| 因素 | 权重 | 说明 |
|------|------|------|
| MatchType | 最高 | exact > prefix > pinyin > substring |
| 文件名长度 | 高 | 短名优先 |
| 使用频率 | 高 | openCount 越高越优先（衰减函数） |
| 修改时间 | 中 | 最近修改优先 |
| 路径深度 | 低 | 浅路径优先 |

使用频率追踪：通过 `NSWorkspace.shared.activateFileViewerSelecting` 检测打开事件，记录到 SQLite side table。MVP 可不实现，但 FileRecord schema 预留字段。

### 3.4 扩展路径

添加新搜索能力：新建 `XxxProvider: SearchProvider` → 注册到 Coordinator → 自动参与查询分发。无需修改现有代码。

---

## 4. UI 层

### 4.1 窗口

- NSPanel 浮动窗口，无标题栏
- **Liquid Glass** 材质：`.glassEffect(.regular, in: .rect(cornerRadius: 24))` — macOS 26 原生玻璃效果
- `.floating` 窗口层级
- 点击外部 / Esc 自动关闭
- 屏幕顶部居中（`NSScreen.main` — 当前活跃屏幕，非主屏幕）
- `GlassEffectContainer` 包裹搜索框和结果列表，统一渲染 + 形态动画

### 4.2 Apple Intelligence 光晕

- **触发条件**：搜索框获得焦点时激活
- **视觉**：AngularGradient 多色旋转描边，叠加在 Liquid Glass 容器外围
  - 颜色：青蓝 / 紫 / 珊瑚粉 / 暖琥珀
  - 旋转周期：~1.8s
  - 4 层叠加（不同线宽 + 模糊半径）
  - 外层柔光 halo
- **M4 优化**：GPU 性能充足，60fps 满帧运行
- **无障碍**：`accessibilityReduceMotion` 时降级为静态渐变边框
- **面板不可见时暂停动画**，避免 GPU 空转
- **索引扫描中**：光晕持续旋转 + 进度文字 "正在索引... x / y 文件"

### 4.3 视图层级

```
SearchPanelView
├── GlassEffectContainer
│   ├── GlowBorderView (Apple Intelligence 光晕)
│   ├── SearchBarView (图标 + TextField + 清除按钮)
│   │       .glassEffect() — Liquid Glass 搜索栏
│   └── ResultsListView
│       └── ResultRowView
│           ├── 文件图标 (FileIconCache)
│           ├── 文件名 (高亮匹配部分，保留原始大小写)
│           ├── 路径
│           └── 大小 / 日期
│       └── LoadMoreButton ("还有 N 个结果")
```

**文件图标缓存**：

```swift
final class FileIconCache {
    private let cache = NSCache<NSString, NSImage>()

    func icon(forExtension ext: String?) -> NSImage {
        // 按扩展名缓存，目录单独缓存
        // 缓存 16x16 缩放后图标
    }
}
```

### 4.4 交互

| 操作 | 行为 |
|------|------|
| 弹出 | 全局快捷键（默认 `⌥Space`）或菜单栏图标 |
| 关闭 | Esc / 点击外部 / 失焦 |
| 导航 | ↑↓ 选择，Enter 打开 |
| 预览 | Space 快速 Look |
| 右键 | 在 Finder 中显示 / 复制路径 / 拖拽 |

### 4.5 无障碍

- 所有交互元素设置 Accessibility identifier 和 label
- VoiceOver：ResultRowView 读出 "文件名，路径，大小"
- 高对比度模式：光晕替换为实线彩色边框
- 键盘导航完整覆盖，focus ring 可见

---

## 5. 全局快捷键 & 生命周期

### 5.1 快捷键

- 默认 `⌥Space`（Option + Space），可配置
- 优先 Carbon `RegisterEventHotKey`（轻量，不注册全局事件监听器）
- CGEventTap 作 fallback
- 首次启动引导授权 Accessibility（系统设置 → 隐私与安全 → 辅助功能）
- 快捷键冲突检测

### 5.2 启动流程

```
App Launch
  ├─ 检查 ~/.everything-search/index.db
  ├─ [存在] 加载 FileRecord[] (SQLite, <1s)
  │         重建内存索引 (Trie + FullSubstringMap + Trigram, <2s)
  │         indexState = .stale → 立即可搜索
  ├─ [不存在] 全量扫描 → 边扫边建索引 → 显示进度
  ├─ 启动 FSEventStream（立即捕获变更）
  ├─ getHistoricalEvents 补齐 cursor 差距（如有）
  ├─ 后台全量验证 → indexState = .verifying
  ├─ 验证完成 → indexState = .live
  └─ 注册快捷键 + 菜单栏图标 → 就绪
```

### 5.3 应用配置

- `LSUIElement = true`：不显示 Dock 图标和 Cmd+Tab
- 支持 Login Item 开机自启
- 退出时保存 FSEvents cursor + flush 剩余变更到 SQLite

---

## 6. 安全

| 措施 | 说明 |
|------|------|
| 文件权限 | ~/.everything-search/ 目录 700，文件 600 |
| 隐私排除 | 默认不索引 Caches/Cookies/Keychains |
| 用户范围 | 只索引当前用户 home + 系统共享目录 |
| 沙盒 | 不适用（需 Full Disk Access），不上架 App Store |
| 分发 | GitHub Releases + Homebrew Cask |
| 公证 | Apple Developer Program 签名 + `xcrun notarytool submit` |
| 快捷键 | 优先 RegisterEventHotKey（不注册全局事件监听） |
| AI API Key | 用户自有 API Key 存储在 macOS Keychain（不存明文，不上传） |
| AI 网络传输 | 所有云端请求强制 HTTPS/TLS 1.3 |
| AI 元数据脱敏 | 发送到云端的路径默认脱敏（/Users/xxx/ → ~/），可在设置中关闭 |
| AI 默认关闭 | 所有 AI 功能默认关闭，用户主动开启才生效 |

---

## 7. 项目结构

```
everything-search/
├── Package.swift
├── Sources/
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   └── StatusBarController.swift
│   ├── UI/
│   │   ├── SearchPanel/
│   │   │   ├── SearchPanelView.swift
│   │   │   ├── SearchBarView.swift
│   │   │   ├── ResultsListView.swift
│   │   │   ├── ResultRowView.swift
│   │   │   └── QuickLookPreview.swift
│   │   ├── Glow/
│   │   │   ├── IntelligenceGlow.swift
│   │   │   └── GlowGradientPalette.swift
│   │   └── Settings/
│   │       └── SettingsView.swift
│   ├── Search/
│   │   ├── SearchCoordinator.swift
│   │   ├── SearchProvider.swift
│   │   ├── SearchQuery.swift
│   │   └── SearchResult.swift
│   ├── Index/
│   │   ├── IndexingEngine.swift            // actor
│   │   ├── InMemoryIndex.swift             // actor
│   │   ├── FileScanner.swift
│   │   ├── FSEventWatcher.swift
│   │   ├── FileSystemEventStream.swift     // protocol + impl + mock
│   │   ├── Trie.swift
│   │   ├── FullSubstringMap.swift
│   │   ├── TrigramIndex.swift              // 长文件名兜底
│   │   ├── PinyinIndex.swift
│   │   ├── FileRecord.swift
│   │   └── IndexPersistence.swift          // SQLite WAL
│   ├── Hotkey/
│   │   └── GlobalHotkey.swift
│   ├── AI/                      # v3.0 新增
│   │   ├── AIModelProvider.swift
│   │   ├── AIContext.swift
│   │   ├── AICapability.swift
│   │   ├── DeepSeekProvider.swift
│   │   ├── QwenProvider.swift
│   │   ├── LocalVisionProvider.swift
│   │   ├── LocalSpeechProvider.swift
│   │   └── AISearchCoordinator.swift
│   └── Utils/
│       ├── FileIconCache.swift
│       └── PathUtils.swift
├── Resources/
│   ├── Assets.xcassets
│   └── menu-icon.pdf
└── Tests/
    ├── IndexTests/
    │   ├── TrieTests.swift
    │   ├── TrigramIndexTests.swift
    │   ├── FullSubstringMapTests.swift
    │   ├── PinyinIndexTests.swift
    │   ├── InMemoryIndexTests.swift
    │   ├── InMemoryIndexPerformanceTests.swift
    │   ├── FileScannerTests.swift
    │   ├── IndexPersistenceTests.swift
    │   └── IndexRecoveryTests.swift
    ├── SearchTests/
    │   ├── SearchCoordinatorTests.swift
    │   └── SearchProviderContractTests.swift
    ├── UITests/
    │   └── SearchPanelUITests.swift
    ├── HotkeyTests/
    │   └── GlobalHotkeyTests.swift
    └── Fixtures/
        ├── FileRecordGenerator.swift
        ├── EdgeCaseFixtures.swift
        └── PerformanceFixtures.swift
```

---

## 8. 性能基准（M4+ 目标）

| 指标 | 目标 | 测试方法 |
|------|------|----------|
| 索引构建 (100k 文件) | < 3s | 合成 FileRecord 数组 |
| 索引构建 (1M 文件) | < 10s | 合成 FileRecord 数组 |
| 前缀查询 (Trie) | < 2ms (p99) | 1M-record 索引, 10k 查询 |
| 子串查询 (FullSubstringMap) | < 1ms (p99) | 1M-record 索引, 10k 查询, O(1) 直查 |
| 拼音查询 | < 15ms (p99) | 1M-record 索引, 10k 查询 |
| 启动加载 (1M 文件) | < 1s | SQLite → 内存重建 |
| 内存 (1M 文件) | < 2GB | malloc_size / Instruments (全子串映射，速度优先) |
| 增量更新 (100 events) | < 10ms | 热索引批量插入/删除 |

使用 `XCTMetric` + `measure` blocks 编码为自动化测试。CI 中作为独立 target 运行，跟踪回归。

---

## 9. 实现顺序（v0.1 — v1.0 开发阶段）

对应 CLAUDE.md 版本路线图中 v0.1-v0.5 + v1.0。v1.1 以后见 CLAUDE.md。

| Phase | 对应版本 | 内容 | 依赖 |
|-------|---------|------|------|
| 1 | v0.1 | FileRecord → Trie → FullSubstringMap → TrigramIndex → PinyinIndex → InMemoryIndex (actor) → Fixtures + Tests | 无 |
| 2 | v0.2 | FileSystemEventStream protocol → FileScanner → FSEventWatcher → IndexPersistence → IndexRecovery | Phase 1 |
| 3 | v0.3 | SearchProvider 协议 → SearchCoordinator → Performance benchmarks | Phase 2 |
| 4 | v0.4 | SearchPanelView → SearchBarView → ResultsListView → IntelligenceGlow → FileIconCache | Phase 3 |
| 5 | v0.5 | GlobalHotkey → StatusBar → AppDelegate → Settings | Phase 4 |
| 6 | v1.0 | QuickLook → 右键菜单 → 拖拽 → UI tests → 打磨 | Phase 5 |
