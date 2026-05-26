# Everything Search - macOS Design Spec

对标 Windows Everything 的 macOS 极速文件搜索工具。

## 项目概要

| 项目 | 值 |
|------|-----|
| 名称 | everything-search |
| 平台 | macOS only (Apple Silicon + Intel) |
| 最低系统 | macOS 14 (Sonoma) |
| 技术栈 | Swift + SwiftUI |
| 应用形态 | Menu Bar App (LSUIElement=true) |
| 开源 | 是 |
| 数据目录 | ~/.everything-search/ |

## MVP 范围

**只做文件名搜索**，架构为后续功能预留扩展性：

| 阶段 | 功能 |
|------|------|
| MVP | 文件名搜索（前缀 + 子串） |
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
│  - 防抖输入 (150ms)                               │
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
│              IndexingEngine                      │
│  ┌──────────────┐  ┌────────────────────────┐  │
│  │  FileScanner │  │  FSEventWatcher        │  │
│  │  (全量扫描)   │  │  (增量更新)             │  │
│  └──────┬───────┘  └───────────┬────────────┘  │
│         │                      │                │
│  ┌──────▼──────────────────────▼────────────┐  │
│  │         InMemoryIndex                     │  │
│  │  - Trie (前缀匹配)                        │  │
│  │  - ReverseTrie (后缀匹配)                 │  │
│  │  - SubstringIndex (全子串 / trigram)      │  │
│  │  - FileRecord[] (路径、大小、日期)        │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### 模块职责

| 模块 | 职责 |
|------|------|
| SearchPanel | SwiftUI 浮动窗口，Spotlight 风格 UI + Apple Intelligence 光晕 |
| SearchCoordinator | 输入防抖、查询分发、结果合并排序 |
| SearchProvider (协议) | 统一搜索接口，每个搜索引擎实现此协议 |
| FileIndexProvider | MVP 唯一的 Provider，调用自建索引 |
| IndexingEngine | 文件扫描 + FSEvents 监听 → 维护内存索引 |
| InMemoryIndex | Trie + ReverseTrie + SubstringIndex，纯内存 |

### 依赖方向

```
App → UI → Search → Index
              ↑
           Hotkey ← App
```

依赖单向向下，无循环。Index 层不依赖 UI，可独立测试。

---

## 2. 索引引擎

### 2.1 数据模型

```swift
struct FileRecord {
    let id: UInt32
    let name: String
    let path: String
    let parentPath: String
    let isDirectory: Bool
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
    let extension: String?
}
```

### 2.2 索引结构（速度优先，内存不是瓶颈）

| 索引 | 结构 | 用途 | 查询速度 |
|------|------|------|----------|
| Trie | 正序字典树 | 前缀匹配、即时补全 | O(k) |
| ReverseTrie | 倒序字典树 | 后缀匹配 | O(k) |
| SubstringIndex | 全子串映射（文件名 ≤ 64 字符）/ trigram（> 64 字符） | 任意子串匹配 | O(1) 直查 |

**全子串索引示例**（文件名 ≤ 64 字符时）：

```
文件名 "report.pdf" 的所有子串均映射到该 FileRecord.ID:
"r", "re", "rep", ..., "report.pdf", "e", "ep", ..., "df", ...
→ 查询 "port" 直接命中，无需合并
```

**大文件名退化为 trigram**（> 64 字符）：

```
文件名 "very-long-filename..." → trigram 分词
"ver", "ery", "ry-", "y-l", ... → 各 trigram 映射到 FileRecord.ID
查询时取交集
```

### 2.3 全量扫描

- `FileManager.enumerator(at:rootURL, ...)` 遍历所有卷
- 跳过：`/System`, `/Library`, `.Trash`, `.git`, `node_modules`, `.Spotlight-V100` 等，可配置
- `TaskGroup` 按卷并行扫描
- 边扫边建索引：扫描过程中即可搜索，不等全部完成

**预估性能**：百万文件首次扫描 20-40 秒，索引内存 100-300MB。

### 2.4 FSEvents 增量更新

| 事件 | 操作 |
|------|------|
| 文件创建 | 插入索引 |
| 文件删除 | 移除索引 |
| 文件重命名 | 删除旧记录 + 插入新记录 |
| 文件修改 | 更新元数据（大小、日期） |

- FSEvents 回调天然批量合并
- 冷启动时用 `getHistoricalEvents` 补齐上次退出后的变更

### 2.5 持久化

```
~/.everything-search/
├── index.db          # 持久化索引
├── config.json       # 用户配置
└── log/              # 运行日志
```

- 启动时优先加载持久化索引（1-3 秒），立即可搜索
- 后台异步做全量扫描校验新鲜度
- 校验完成后切换到 FSEvents 实时模式
- 索引变更实时增量持久化，不累积到退出时
- 退出时保存 FSEvents cursor，下次从 cursor 恢复

---

## 3. SearchProvider 协议 & 搜索流程

### 3.1 协议

```swift
protocol SearchProvider {
    var name: String { get }
    var isReady: Bool { get }

    func search(query: SearchQuery) -> [SearchResult]
    func searchAsync(query: SearchQuery) async -> [SearchResult]
    func prepare() async
}

struct SearchQuery {
    let text: String
    let limit: Int
    let options: SearchOptions
}

struct SearchResult {
    let record: FileRecord
    let provider: String
    let score: Double
    let matchType: MatchType
}

enum MatchType {
    case exact
    case prefix
    case suffix
    case substring
    case regex       // future
    case semantic    // future
}
```

### 3.2 SearchCoordinator 流程

```
用户输入 → 150ms 防抖 → 构建 SearchQuery → 遍历 ready Providers → 合并结果 → 排序 → 渲染
```

### 3.3 排序策略

| 因素 | 权重 |
|------|------|
| MatchType | exact > prefix > suffix > substring |
| 文件名长度 | 短名优先 |
| 修改时间 | 最近修改优先 |
| 路径深度 | 浅路径优先 |

### 3.4 扩展路径

添加新搜索能力：新建 `XxxProvider: SearchProvider` → 注册到 Coordinator → 自动参与查询分发。无需修改现有代码。

---

## 4. UI 层

### 4.1 窗口

- NSPanel 浮动窗口，无标题栏，透明背景
- `.floating` 窗口层级
- `.ultraThinMaterial` 毛玻璃背景
- 点击外部 / Esc 自动关闭
- 屏幕顶部居中（Spotlight 同款位置）

### 4.2 Apple Intelligence 光晕

- **触发条件**：搜索框获得焦点时激活光晕
- **视觉**：AngularGradient 多色旋转描边
  - 颜色：青蓝 / 紫 / 珊瑚粉 / 暖琥珀
  - 旋转周期：~1.8s
  - 4 层叠加（不同线宽 + 模糊半径），营造深度感
  - 外层柔光 halo
- **空闲时**：无光晕，仅搜索图标
- **索引扫描中**：光晕持续旋转 + 进度文字 "正在索引... x / y 文件"

### 4.3 视图层级

```
SearchPanelView
├── GlowBorderView (IntelligenceStrokeView)
├── SearchBarView (图标 + TextField + 清除按钮)
└── ResultsListView
    └── ResultRowView (图标 + 文件名高亮 + 路径 + 大小)
```

### 4.4 交互

| 操作 | 行为 |
|------|------|
| 弹出 | 全局快捷键（默认 `⌥Space`）或菜单栏图标 |
| 关闭 | Esc / 点击外部 / 失焦 |
| 导航 | ↑↓ 选择，Enter 打开 |
| 预览 | Space 快速 Look |
| 右键 | 在 Finder 中显示 / 复制路径 / 拖拽 |

---

## 5. 全局快捷键 & 生命周期

### 5.1 快捷键

- 默认 `⌥Space`（Option + Space），可配置
- Carbon `RegisterEventHotKey` API 或 `CGEventTap`
- 首次启动引导授权 Accessibility 权限
- 快捷键冲突检测

### 5.2 启动流程

```
App Launch
  ├─ [index.db 存在] → 加载持久化索引 (1-3s) → 可搜索 → 后台校验
  ├─ [index.db 不存在] → 全量扫描 → 边扫边搜 → 显示进度
  ├─ 启动 FSEventStream
  └─ 注册快捷键 + 菜单栏图标 → 就绪
```

### 5.3 应用配置

- `LSUIElement = true`：不显示 Dock 图标和 Cmd+Tab
- 支持 Login Item 开机自启
- 退出时保存 FSEvents cursor

---

## 6. 项目结构

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
│   │   ├── IndexingEngine.swift
│   │   ├── FileScanner.swift
│   │   ├── FSEventWatcher.swift
│   │   ├── InMemoryIndex.swift
│   │   ├── Trie.swift
│   │   ├── FileRecord.swift
│   │   └── IndexPersistence.swift
│   ├── Hotkey/
│   │   └── GlobalHotkey.swift
│   └── Utils/
│       ├── FileIconLoader.swift
│       └── PathUtils.swift
├── Resources/
│   ├── Assets.xcassets
│   └── menu-icon.pdf
└── Tests/
    ├── IndexTests/
    │   ├── TrieTests.swift
    │   ├── InMemoryIndexTests.swift
    │   └── IndexPersistenceTests.swift
    └── SearchTests/
        └── SearchCoordinatorTests.swift
```

---

## 7. 实现顺序

| Phase | 内容 | 依赖 |
|-------|------|------|
| 1 | FileRecord → Trie → InMemoryIndex → FileScanner → FSEventWatcher → IndexPersistence | 无 |
| 2 | SearchProvider 协议 → SearchCoordinator | Phase 1 |
| 3 | SearchPanelView → SearchBarView → ResultsListView → IntelligenceGlow | Phase 2 |
| 4 | GlobalHotkey → StatusBar → AppDelegate → Settings | Phase 3 |
| 5 | QuickLook → 右键菜单 → 拖拽 → 性能调优 | Phase 4 |
