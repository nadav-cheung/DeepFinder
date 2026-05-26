# Everything Search - macOS Design Spec

对标 Windows Everything 的 macOS 极速文件搜索工具。

## 项目概要

| 项目 | 值 |
|------|-----|
| 名称 | everything-search |
| 平台 | macOS only, Apple Silicon M4+ |
| 最低系统 | macOS 15 (Sequoia) |
| 架构 | arm64 only |
| 技术栈 | Swift + SwiftUI |
| 应用形态 | Menu Bar App (LSUIElement=true) |
| 开源 | 是 |
| 数据目录 | ~/.everything-search/ |
| 分发渠道 | GitHub Releases + Homebrew Cask |

## MVP 范围

**只做文件名搜索**，架构为后续功能预留扩展性：

| 阶段 | 功能 |
|------|------|
| MVP | 文件名搜索（前缀 + 子串 + 拼音） |
| V2 | 高级搜索语法（通配符、正则、布尔表达式） |
| V3 | 元数据过滤（大小、日期、类型、扩展名） |
| V4 | 内容搜索 |
| V5 | AI 语义搜索 |

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
│    └───────────────────────────────────┘         │
└──────────────────────┬──────────────────────────┘
                       │ query string
┌──────────────────────▼──────────────────────────┐
│              SearchCoordinator                    │
│  - 分发查询给 SearchProvider                      │
│  - 合并 & 排序结果                                │
└──────────────────────┬──────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
┌────────▼───┐  ┌──────▼──────┐  ┌──▼───────────┐
│ FileIndex  │  │  Spotlight  │  │  AI Provider  │
│  Provider  │  │   Provider  │  │   (future)    │
│ (自建索引)  │  │  (mdfind)   │  │              │
└─────┬──────┘  └─────────────┘  └──────────────┘
      │
┌─────▼──────────────────────────────────────────┐
│              IndexingEngine (actor)              │
│  ┌──────────────┐  ┌────────────────────────┐  │
│  │  FileScanner │  │ FileSystemEventStream  │  │
│  │  (全量扫描)   │  │  (FSEvents 抽象层)      │  │
│  └──────┬───────┘  └───────────┬────────────┘  │
│         │                      │                │
│  ┌──────▼──────────────────────▼────────────┐  │
│  │     InMemoryIndex (actor)                 │  │
│  │  - Trie (前缀匹配)                        │  │
│  │  - TrigramIndex (子串匹配)                │  │
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
| SearchPanel | SwiftUI 浮动窗口，Spotlight 风格 UI + Apple Intelligence 光晕 |
| SearchCoordinator | 查询分发、流式结果合并排序 |
| SearchProvider (协议) | 统一搜索接口，返回 AsyncSequence |
| FileIndexProvider | MVP 唯一的 Provider，调用自建索引 |
| IndexingEngine (actor) | 文件扫描 + FSEvents 监听 → 维护内存索引 |
| InMemoryIndex (actor) | Trie + TrigramIndex + PinyinIndex，纯内存 |
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

// 用于排序的辅助数据，不入库
struct UsageStats {
    let openCount: Int
    let lastOpenedAt: Date?
}
```

所有文件名入库前做 **NFC 统一化**（`name.precomposedStringWithCanonicalMapping`），查询时同样统一化。

### 2.2 索引结构（速度优先）

| 索引 | 结构 | 用途 | 查询速度 | 内存/文件 |
|------|------|------|----------|-----------|
| Trie | Unicode scalar 字典树 | 前缀匹配、即时补全 | O(k) | O(n) |
| FullSubstringMap | 子串 → [FileRecord.ID] 直接映射 | 任意子串 O(1) 命中 | O(1) | O(n²) |
| TrigramIndex | trigram → [FileRecord.ID] posting list | 长文件名(>64字符)子串匹配 | O(1) → 交集 → 验证 | O(n) |

**设计原则：速度第一，内存不是瓶颈。**

- 文件名 ≤64 字符：建 **全子串映射**（所有子串直接指向 FileRecord.ID），查询 O(1) 零计算
- 文件名 >64 字符：退化为 trigram + 交集验证（长文件名极少见）
- M4+ 统一内存架构，1M 文件的全子串映射约占 1-2GB，可接受

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
- `TaskGroup` 按卷并行扫描
- 使用 `DispatchQueue.global(qos: .utility)` 降低优先级，避免影响前台
- 边扫边建索引：扫描过程中即可搜索，不等全部完成

**M4+ 性能预估**：百万文件首次扫描 < 10 秒。全量扫描使用 `DispatchQueue.global(qos: .userInitiated)` 高优先级（用户主动启动，速度优先）。

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
- 不持久化 Trie / TrigramIndex 结构 → 启动时从 FileRecord[] 重建（M4 上 ~1-2s）
- 增量持久化：内存缓冲变更，每 5 秒或每 100 条变更批量写入（避免 FSEvents 高频回调导致 I/O 抖动）
- WAL 模式：读写不互斥
- 索引损坏恢复：加载时校验（行数 + checksum），失败则删除重建 + 进度 UI

**M4+ 性能预估**：启动加载 < 1s，索引重建 < 2s。

---

## 3. SearchProvider 协议 & 搜索流程

### 3.1 协议（流式，支持未来异步/慢查询场景）

```swift
protocol SearchProvider: Sendable {
    var name: String { get }
    var isReady: Bool { get }

    /// 流式搜索，支持增量返回结果。
    /// MVP 的内存索引可一次 yield 全部结果。
    /// 未来的 AI/内容搜索可增量 yield。
    func search(query: SearchQuery) -> AsyncSequence<SearchResult, Never>

    /// 取消进行中的查询
    func cancel(queryID: String)

    /// Provider 初始化/预热
    func prepare() async
}

struct SearchQuery: Sendable {
    let id: String             // 唯一查询 ID，用于取消
    let text: String           // 已 NFC 统一化
    let limit: Int             // 默认 100
    let options: SearchOptions
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

- NSPanel 浮动窗口，无标题栏，透明背景
- `.floating` 窗口层级
- `.ultraThinMaterial` 毛玻璃背景
- 点击外部 / Esc 自动关闭
- 屏幕顶部居中（`NSScreen.main` — 当前活跃屏幕，非主屏幕）

### 4.2 Apple Intelligence 光晕

- **触发条件**：搜索框获得焦点时激活
- **视觉**：AngularGradient 多色旋转描边
  - 颜色：青蓝 / 紫 / 珊瑚粉 / 暖琥珀
  - 旋转周期：~1.8s
  - 4 层叠加（不同线宽 + 模糊半径）
  - 外层柔光 halo
- **M4 优化**：GPU 性能充足，4 层光晕无性能压力。60fps 满帧运行
- **无障碍**：`accessibilityReduceMotion` 时降级为静态渐变边框
- **面板不可见时暂停动画**，避免 GPU 空转
- **索引扫描中**：光晕持续旋转 + 进度文字 "正在索引... x / y 文件"

### 4.3 视图层级

```
SearchPanelView
├── GlowBorderView (IntelligenceStrokeView)
├── SearchBarView (图标 + TextField + 清除按钮)
└── ResultsListView
    └── ResultRowView
        ├── 文件图标 (FileIconCache)
        ├── 文件名 (高亮匹配部分)
        ├── 路径
        └── 大小 / 日期
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
  │         重建内存索引 (Trie + Trigram, <2s)
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
│   │   ├── FullSubstringMapTests.swift
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

## 9. 实现顺序

| Phase | 内容 | 依赖 |
|-------|------|------|
| 1 | FileRecord → Trie → TrigramIndex → PinyinIndex → InMemoryIndex (actor) → Fixtures + Tests | 无 |
| 2 | FileSystemEventStream protocol → FileScanner → FSEventWatcher → IndexPersistence → IndexRecovery | Phase 1 |
| 3 | SearchProvider 协议 → SearchCoordinator → Performance benchmarks | Phase 2 |
| 4 | SearchPanelView → SearchBarView → ResultsListView → IntelligenceGlow → FileIconCache | Phase 3 |
| 5 | GlobalHotkey → StatusBar → AppDelegate → Settings | Phase 4 |
| 6 | QuickLook → 右键菜单 → 拖拽 → UI tests → 打磨 | Phase 5 |
