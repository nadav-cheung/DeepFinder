# DeepFinder 开源准备度评估报告

**项目**: DeepFinder v3.0.0
**评估日期**: 2026-05-31 *(updated 2026-06-02)*
**评估人**: Bruce (布鲁斯) — 自动化分析
**语言**: 简体中文

---

## 一、产品概览

### 1.1 产品定位

DeepFinder 是一款 macOS 26 文件搜索引擎，对标 Windows Everything。**速度是第一优先级——内存和 CPU 不是约束。** 基于 Apple Silicon M4+ arm64 架构，纯 Swift 实现，零外部依赖。

**核心特点**:
- **即时搜索**: 守护进程常驻内存，CLI 通过 Unix domain socket 通信，亚毫秒级查询延迟
- **全类型索引**: 前缀树 (Trie) + 全覆盖子串映射 (FullSubstringMap) + 三元组索引 (TrigramIndex) + 拼音索引 (PinyinIndex)，支持中文文件名搜索
- **隐私优先 AI**: 本地端 Vision/Speech 分析，云端 AI (DeepSeek, Qwen) 仅发送匿名化元数据（文件名、大小、类型，不含文件内容），所有 AI 功能默认关闭
- **v2.0 GUI**: Liquid Glass 效果面板 + Apple Intelligence Glow 动画 + 全局热键 (Ctrl+Cmd+K)

### 1.2 技术栈

| 维度 | 技术选择 |
|------|---------|
| 语言 | Swift 6.2 |
| 最低系统 | macOS 26 (Tahoe), Apple Silicon M4+ arm64 |
| 构建系统 | Swift Package Manager (swift-tools-version 6.2) |
| 外部依赖 | 零 — 仅 Apple 框架 (Foundation, CoreServices, Carbon, SQLite3, SwiftUI, AppKit, Vision, Speech, PDFKit, AVFoundation, ImageIO) |
| 系统链接 | libedit (Darwin.readline) |
| 并发模型 | Actor isolation + async/await + Swift 6 Sendable 全量合规 |
| 持久化 | SQLite WAL (0600 权限) |
| IPC | Unix domain socket + 4 字节长度前缀 + JSON |
| 测试框架 | Swift Testing (主导) + XCTest (遗留 97 tests) |

### 1.3 版本历程

| 版本 | 日期 | 里程碑 | 提交数 |
|------|------|--------|--------|
| v0.1.0 | 2026-05-29 | 索引核心: FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex (76 tests) | 基线 |
| v0.2.0 | 2026-05-30 | 文件系统: FSEventStream, FileScanner, FSEventWatcher, IndexPersistence | +2 |
| v0.3.0 | 2026-05-30 | 搜索层: SearchProvider 协议, SearchCoordinator actor, benchmarks | +4 |
| v0.4.0 | 2026-05-30 | 守护进程 + IPC: DaemonMain, IPCServer (Unix socket + JSON), PID 管理, LaunchAgent | +3 |
| v0.5.0 | 2026-05-30 | CLI 单次搜索: 参数解析, TerminalFormatter (ANSI), --json/--0/--sort/--limit | +3 |
| v0.6.0 | 2026-05-30 | 交互式 REPL: readline 循环, :help/:stats/:open/:reveal, 持久化历史 | +3 |
| v0.7.0 | 2026-05-30 | 守护进程管理: start/stop/restart/install, config get/set | 0 |
| v1.0.0 | 2026-05-30 | CLI 正式发布: 完整 CLI + daemon + REPL + single-shot | 0 |
| v1.1.0 | 2026-05-30 | 高级语法: 布尔/通配符/正则/路径限定/修饰符/搜索历史 | +3 |
| v1.2.0 | 2026-05-30 | 元数据过滤: size/date/ext/type 过滤 | 0 |
| v1.3.0 | 2026-05-30 | 搜索体验: 书签, 自定义过滤器, 排序, 搜索建议 | 0 |
| v1.4.0 | 2026-05-30 | 内容搜索: content: 函数, 编码支持, 行号定位 | 0 |
| v1.5.0 | 2026-05-30 | 重复查找: dupe/sizedupe/hashdupe/empty/childcount | +3 |
| v2.0.0 | 2026-05-30 | GUI + 扩展索引: NSPanel + Liquid Glass + Apple Intelligence glow + 全局热键 | +9 |
| v2.1.0 | 2026-05-30 | 媒体元数据: 图片尺寸, 音频标签, 视频信息, PDF 元数据 | +6 |
| v2.2.0 | 2026-05-30 | 服务集成: HTTP 搜索 API, URL scheme, Shortcuts, AppleScript | +13 |
| **v3.0.0** | **2026-05-30** | **AI 语义搜索**: 自然语言查询, 端侧 Vision/Speech, 可选云 AI, 隐私优先 | +13 |

总计 17 个 tag，90 次提交，全部在一人两天内完成（May 29-30, 2026）。

### 1.4 代码规模与测试覆盖

| 模块 | 源文件数 | 测试文件数 | 测试数 |
|------|---------|-----------|--------|
| Index (索引核心) | 7 | 6 | 76 |
| FS (文件系统) | 6 | 4 | 51 |
| Search (搜索) | 15 | 14 | 149 |
| Persist (持久化) | 2 | 2 | 20 |
| Daemon (守护进程) | 6 | 5 | 52 |
| CLI (命令行) | 13 | 10 | 126 |
| GUI (图形界面) | 18 | 13 | 177 |
| AI (人工智能) | 21 | 20 | 204 |
| Media (媒体元数据) | 7 | 8 | 56 |
| Services (服务集成) | 4 | 5 | 62 |
| **总计** | **99** | **101** | **1142** |

- 测试文件率: 101/99 = 102% (some modules have more test files than source files)
- 所有测试通过，项目 clean 编译
- 需求文档: 121 个 REQ，覆盖 v0.1 到 v3.1 共 18 个版本模块

---

## 二、各维度评分汇总

| 评估维度 | 评分 (满分10) | 等级 | 关键问题 |
|---------|-------------|------|---------|
| 架构设计 | 7.0 | 良好 | 单体编译目标与文档矛盾 |
| 功能完整度 | 8.0 | 良好 | v1.2 和 v1.0 缺口已修复 (2026-06-01/02) |
| 代码质量 | 7.0 | 良好 | 无日志框架，try? 过度使用 |
| 测试质量 | 5.8 | 待改进 | 无 CI, 无 Index 层性能基准 |
| 文档完整度 | 6.5 | 中等 | 2026-06-02 review fixed many doc/impl mismatches |
| 安全评估 | 6.6 | 中等 | IPC 无认证，数据库明文 |
| 性能评估 | 5.6 | 待改进 | 缺少规模化基准测试 |
| 总体开源准备度 | **6.0** | **基本就绪，基础设施完善中** | v1.0/v1.2 修复，文档更新，仍缺 CI/LICENSE |

**综合雷达图描述** (文本格式):

```
           架构设计 (7.0)
               /\
              /  \
             /    \
   安全(6.6)       功能(6.0)
           |        |
           |   ★    |
   测试(5.8)--------代码(7.0)
           | 5.2    |
           |        |
   文档(5.5)------性能(5.6)
```

**总体评分: 6.0/10 — 代码和架构质量较高，开源基础设施逐步完善中 (updated 2026-06-02)。**

---

## 三、架构评估

### 3.1 模块结构

```
Sources/
├── Index/     (7 files)   — 核心内存索引: FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex
├── FS/        (6 files)   — 文件系统层: FileScanner, FSEventStream, FSEventWatcher, VolumeManager
├── Search/    (15 files)  — 搜索层: SearchProvider, SearchCoordinator, QueryParser, FilterPipeline, ContentScanner, DuplicateFinder
├── Persist/   (2 files)   — 持久化: IndexPersistence (SQLite WAL), IndexRecovery
├── Daemon/    (6 files)   — 守护进程: DaemonMain, IPCServer, IPCClient, IPCProtocol, LaunchAgent, ConfigStore
├── CLI/       (13 files)  — 命令行: CLIMain, SingleShot, REPL, TerminalFormatter, REPLCommands, IPCClient
├── GUI/       (18 files)  — 图形界面: SearchPanelView, GlassEffectContainer, GlobalHotkey, QuickLookPreview, SettingsView
├── Media/     (7 files)   — 媒体元数据: Image/Audio/Video/PDFMetadataExtractor, MediaMetadataIndex
├── Services/  (4 files)   — 服务集成: HTTPSearchService, URLSchemeHandler, SearchIntent, SearchScriptCommand
├── AI/        (21 files)  — AI 模块: NLSearchTranslator, DeepSeekProvider, QwenProvider, LocalVisionProvider, LocalSpeechProvider
```

**重要发现**: Package.swift 将所有 99 个源文件编译为 **单一** 的 `DeepFinder` library target (path: `Sources`)。CLAUDE.md 描述的独立 target (DeepFinderIndex library, DeepFinderDaemon executable, DeepFinderCLI executable) **并不存在**。所有代码默认为 `internal` 访问级别——没有实际的模块边界和公共 API。

### 3.2 依赖方向

```
CLI / GUI → Daemon (IPC) → Search (SearchCoordinator) → Index (InMemoryIndex)
                ↓                          ↓
            Persist (SQLite)          FS (FSEventStream)
```

依赖方向严格单向，无循环依赖。但编译层面无强制——因为所有代码在同一 target 中。

### 3.3 架构优势

1. **Actor 并发模型一致性**: 23 个 actor 统一隔离可变状态，全量 Swift 6 Sendable 合规
2. **协议驱动扩展**: SearchProvider (3 methods), AIModelProvider (2 methods + 能力声明), MetadataExtractor (2 methods), FileSystemEventStream (测试抽象)
3. **可测试性内建**: IPCClientProtocol, WorkspaceProtocol, FileSystemEventStream, REPLInputSource 等协议抽象使 mock 注入成为可能
4. **零外部依赖**: 降低供应链风险，简化贡献者环境搭建
5. **全面的内联文档**: 每个公开类型/属性/方法都有 `///` 文档注释，模块级注释解释架构和数据流

### 3.4 架构问题

| 严重度 | 问题 | 影响 |
|--------|------|------|
| **Critical** | 单体编译目标与文档描述矛盾。Package.swift 为单 target，无 module boundary，无 public API | 外部无法使用 DeepFinder 作为依赖，无编译器级分层强制 |
| **Critical** | Package.swift 设置 `.macOS(.v26)` — macOS 26 尚未公开发布 | 几乎无人能编译运行，贡献者基数为零 |
| **High** | 所有代码默认 `internal` — 无 public API surface。即使内联文档优秀，外部不可见 | 不能作为 Swift 包被其他项目依赖 |
| **High** | DaemonMain.waitForShutdown() 使用 100ms 轮询循环而非 AsyncStream | 不必要的 CPU 消耗 |
| **Medium** | CLAUDE.md 声明的 IndexingEngine actor 不存在 — daemon 直接处理协调逻辑 | 文档与实现脱节 |

---

## 四、功能完整度

### 4.1 版本完成情况

| 版本 | 完成度 | 状态 |
|------|--------|------|
| v0.1 (索引核心) | 100% | ✅ 完成 |
| v0.2 (文件系统) | 100% | ✅ 完成 |
| v0.3 (搜索) | 100% | ✅ 完成 |
| v0.4 (守护进程+IPC) | 100% | ✅ 完成 |
| v0.5 (CLI 单次搜索) | 100% | ✅ 完成 |
| v0.6 (交互式 REPL) | 100% | ✅ 完成 |
| v0.7 (守护进程管理) | 100% | ✅ 完成 |
| v1.0 (CLI 正式发布) | 100% | ✅ 完成 (Homebrew formula, man page, shell completions added) |
| v1.1 (高级语法) | 100% | ✅ 完成 |
| v1.2 (元数据过滤) | **100%** | ✅ FilterPipeline 已接入 SearchCoordinator (lines 129-130) |
| v1.3 (搜索体验) | 100% | ✅ 完成 |
| v1.4 (内容搜索) | 100% | ✅ 完成 |
| v1.5 (重复查找) | 100% | ✅ 完成 |
| v2.0 (GUI) | 100% | ✅ 完成 |
| v2.1 (媒体元数据) | 100% | ✅ 完成 |
| v2.2 (服务集成) | 100% | ✅ 完成 |
| v3.0 (AI 语义) | 100% | ✅ 完成 |
| v3.1 (本地 RAG) | 0% | ❌ 仅有 spec，零代码 |

### 4.2 已知功能缺口

#### ~~🔴 Critical: v1.2 元数据过滤未接线~~ ✅ 已修复 (2026-06-01)

~~这是最大的功能性 bug——不是缺失功能，而是**已完成、已测试的功能被结构性地断开了连接**。~~

**已修复**: FilterPipeline 已接入 SearchCoordinator.search() (lines 129-130)。所有 8 个 v1.2 REQs 确认完成。详见 REQ_STATUS.md 变更日志 2026-06-01 条目。

<details>
<summary>原始发现（已过时）</summary>

**问题链路**:
1. `FilterPipeline.parse()` 正确处理 17+ 修饰键（size, ext, dm, depth, width, height, duration, fps, bitRate, artist, album, title, genre, codec 等），有 10 个通过的单元测试
2. `SearchCoordinator.search(query:filters:)` 正确接受和应用过滤器
3. **但是**: `QueryParser.modifierKeys` (QueryTerm.swift:88) 只识别 5 个键 `["case", "file", "folder", "ext", "path"]`
4. **但是**: `IPCServer.dispatchRequest()` 调用 `coordinator.search(query:)` 时总是传 `filters=[]`
5. **结果**: 用户输入 `"report size:>10mb"` 或 `"photo dm:thisweek"` 时，修饰符被**静默丢弃**，结果等同于只搜索 `"report"` 或 `"photo"`

**预计修复工作量**: 2-3 天

</details>

#### 🟡 Other Gaps

- **v1.0**: Homebrew formula, man page (deepfinder.1), shell completions (bash/zsh/fish) 完全缺失
- **v1.2**: dc: (创建日期) 和 da: (访问日期) 过滤器枚举已定义但无代码路径构造
- **v3.1**: 本地 RAG 全部未开始（7 个 REQ, 零代码）
- **GUI**: 首次启动无引导流程，错误状态静默吞没，AI 功能默认关闭且无引导卡片

### 4.3 与竞品对比

| 维度 | DeepFinder | Everything (Win) | Spotlight (macOS) | Alfred | Raycast |
|------|-----------|-----------------|-------------------|--------|---------|
| 搜索速度 | ⭐⭐⭐⭐⭐ 亚毫秒 | ⭐⭐⭐⭐⭐ 即时 | ⭐⭐⭐ 中等 | ⭐⭐⭐⭐ 快 | ⭐⭐⭐⭐ 快 |
| 搜索语法 | ⭐⭐⭐⭐⭐ 全支持 | ⭐⭐⭐⭐ 丰富 | ⭐⭐ 有限 | ⭐⭐⭐ 中等 | ⭐⭐⭐ 中等 |
| 安装便捷性 | ⭐ 需编译 | ⭐⭐⭐⭐⭐ 一键安装 | ⭐⭐⭐⭐⭐ 系统内置 | ⭐⭐⭐⭐⭐ 一键安装 | ⭐⭐⭐⭐⭐ 一键安装 |
| 元数据过滤 | ⭐ (未接线) | ⭐⭐⭐⭐ 可用 | ⭐⭐⭐ 可用 | ⭐⭐⭐ 可用 | ⭐⭐⭐ 可用 |
| GUI 美观 | ⭐⭐⭐⭐⭐ 顶级 | ⭐⭐⭐ 传统 | ⭐⭐⭐ 标准 | ⭐⭐⭐⭐ 可定制 | ⭐⭐⭐⭐ 现代 |
| AI 功能 | ⭐⭐⭐⭐ 创新 | ❌ 无 | ⭐⭐ 基础 | ⭐⭐ 有限 | ⭐⭐⭐⭐ 丰富 |
| 隐私保护 | ⭐⭐⭐⭐⭐ 最佳 | ⭐⭐⭐⭐ 本地 | ⭐⭐⭐ 云端 | ⭐⭐⭐ 本地为主 | ⭐⭐⭐ 混合 |
| 生态系统 | ❌ 无 | ⭐⭐⭐ 有限 | ⭐⭐ 系统级 | ⭐⭐⭐⭐⭐ 成熟 | ⭐⭐⭐⭐⭐ 丰富 |
| 社区规模 | ❌ 无 | ⭐⭐⭐⭐ 大 | N/A 闭源 | ⭐⭐⭐⭐⭐ 大 | ⭐⭐⭐⭐⭐ 大 |

**DeepFinder 的独特优势**:
- 本地 Vision 分析 (CoreML 端侧图像标签，不上传云端)
- 本地 Speech 输入 (Speech framework，隐私保护)
- 隐私优先 AI (路径匿名化，仅元数据，绝不上传文件内容)
- 真正的跨语言搜索
- macOS 26 原生 Liquid Glass + Apple Intelligence Glow 视觉效果

**但当前这些优势无法发挥**，因为：
1. 安装需要手动编译（无 Homebrew）
2. 高级用户尝试的第一个元数据查询就静默失败
3. 查询语法零文档（REPL :help 不显示语法）
4. 无引导流程
5. App 不可见（LSUIElement，无 Dock 图标）

---

## 五、代码质量

### 5.1 命名规范

**评分: 8/10 — 优秀**

- 严格遵循 Swift 标准命名（PascalCase types, camelCase functions/variables）
- 无一 snake_case 违规
- 每个文件使用 `// MARK: -` 分区
- 一类型一文件为主流，少数例外（如 NLOperations.swift 包含 5 个紧密耦合的类型）
- 无重复文件名跨模块

### 5.2 错误处理

**评分: 5/10 — 待改进**

| 模式 | 数量 | 评价 |
|------|------|------|
| 自定义 Error enum (符合 CustomStringConvertible+Error) | 21+ | ✅ 良好，模块级作用域 |
| throw/throws 在协议接口中 | 若干 | ✅ 正确使用 |
| try? 静默压制错误 | 40+ 处 | 🔴 过度使用，无法事后调试 |
| print() 作为错误报告 (CLI) | 若干 | ⚠️ 可用但不结构化 |
| 静默 SQL 失败 (IndexPersistence) | 4 处 | ⚠️ 有意的最高努力策略，但磁盘满/损坏错误不可见 |
| 空 catch 块 | 0 | ✅ 无 |

### 5.3 并发安全

**评分: 9/10 — 优秀**

- 23 个 actor 隔离所有可变状态
- 所有数据传输类型符合 Sendable
- @MainActor 正确限定 6 个 GUI 类
- withTaskGroup 正确使用于并行工作
- Task { [weak self] } 防止 IPC/GUI 中的引用循环
- 10+ `nonisolated(unsafe)` / `@unchecked Sendable` 处均有文档说明安全理由

### 5.4 强制解包

**评分: 7/10 — 良好**

共 6 处真正的 `!` 强制解包，大部分低风险。需关注:

1. `ResultRowView.swift:154-155` — AttributedString.CharacterView.Index 强制解包，德语 ß 等大小写变化可能导致崩溃
2. `SearchFilter.swift:202` — Calendar.date 强制解包，极端情况下可能返回 nil

### 5.5 具体问题清单

| 严重度 | 问题 | 位置 | 影响 |
|--------|------|------|------|
| **Critical** | 无结构化日志框架 — 守护进程零 os_log/Logger | 全局 | 后台运行时崩溃、磁盘满、IPC 失败无任何诊断输出 |
| **High** | IPC 组帧逻辑重复 ~75 行 | Daemon/IPCClient.swift + IPCServer.swift | 维护负担，可能的 bug 不一致 |
| **High** | try? 压制 40+ 处错误 | IPCClient, IndexPersistence, AppDelegate 等 | 事后调试不可能 |
| **High** | SQLite 静默错误 | IndexPersistence.swift: saveRecords, deleteRecords 等 | 持久化数据与内存分离时无信号 |
| **Medium** | 单体 Package.swift — 99 文件同一 target | Package.swift:10-23 | 无编译级模块边界 |
| **Medium** | DateFormatter/JSONEncoder 重复创建 15+ 处 | REPL, SearchFilter, ImageMetadataExtractor 等 | 性能开销 |
| **Medium** | 路径展开 ~/ 重复 9+ 处 | 多文件 | 代码重复 |
| **Medium** | maxMessageSize 常量重复 | IPCClient, IPCServer | 不一致风险 |
| **Low** | ResultRowView 强制解包 | GUI/ResultRowView.swift:154-155 | 罕见崩溃 |
| **Low** | SearchFilter 强制解包 | Search/SearchFilter.swift:202 | 理论风险 |

---

## 六、测试质量

### 6.1 覆盖率分析

| 模块 | 源文件 | 测试文件 | 测试数 | 比率 |
|------|--------|---------|--------|------|
| Index | 7 | 6 | 76 | 0.86 |
| FS | 6 | 4 | 51 | 0.67 |
| Search | 15 | 14 | 149 | 0.93 |
| Persist | 2 | 2 | 20 | 1.00 |
| Daemon | 6 | 5 | 52 | 0.83 |
| CLI | 13 | 10 | 126 | 0.77 |
| GUI | 18 | 13 | 177 | 0.72 |
| AI | 21 | 20 | 204 | 0.95 |
| Media | 7 | 8 | 56 | 1.14 |
| Services | 4 | 5 | 62 | 1.25 |
| **总计** | **99** | **101** | **1142** | **0.88** |

### 6.2 测试质量评估

**优势**:
- 1142 total tests, 所有文件都有测试 — 无空壳文件
- 边界/错误/异常路径覆盖扎实: 162 边缘测试, 64 错误测试, 38 边界测
- 国际化: 32 测试覆盖中文拼音、跨语言搜索
- 有集成测试: CLI IntegrationTests (16 tests), FilterPipeline, ServeMode, REPL

**劣势**:
- **无性能基准测试在 Index 层**: CLAUDE.md 明确要求 Trie, FullSubstringMap 等的 measure block，但只有 SearchBenchmarks.swift 有 3 个
- **框架不一致**: 97 tests (8 文件) 仍使用旧 XCTest，与 Swift Testing 混用
- **GUI 覆盖最薄** (0.72): 10 of 18 源文件无单元测试
- **并发压力测试几乎为零**: 仅 ~2 个专用测试
- **无测试覆盖工具**: 无 .lcov 生成，无覆盖率阈值
- **不确定测试**: Date() 在夹具中，Int64.random 在基准中，Task.sleep 在异步测试中

### 6.3 缺失的测试文件 (27 个)

Index: (无性能基准), FS: FSEventStreamImpl, Search: AutocompleteProvider, ContentScanner, ContentSearchProvider, FileHasher, FileIndexProvider, QueryTerm, CLI: IPCClientProtocol, REPLCommands, SingleShot, Daemon: IPCClient, LaunchAgent, GUI: 10 文件, AI: AIContext, HTTPClient, ImageSimilaritySearch

### 6.4 CI/CD 建议

1. **P0**: 添加 GitHub Actions workflow — `swift build` + `swift test` on push/PR
2. **P1**: 完成 XCTest → Swift Testing 迁移 (8 文件, 97 tests, 约 2-3 天工作量)
3. **P1**: 将 Package.swift 拆分为模块化 test targets 以支持并行 CI
4. **P2**: 添加并发压力测试 (10-100 并发 IPC 客户端)
5. **P2**: 将 Task.sleep 替换为 AsyncStream/continuation 消除时序敏感性
6. **P2**: 配置 .spi.yml + 代码覆盖率工具

---

## 七、文档完整度

### 7.1 现有文档清单

| 文档 | 行数 | 质量 |
|------|------|------|
| README.md | 237 | ⭐⭐⭐⭐ 良好 — 功能、快速启动、示例、架构概览、AI 隐私表 |
| CONTRIBUTING.md | 185 | ⭐⭐⭐⭐ 良好 — 环境搭建、TDD、代码风格、并发、PR 流程 |
| CLAUDE.md | ~350 | ⭐⭐⭐ 中等 — 内容好但状态严重过期 (说 v0.1.0) |
| 架构设计 spec | 1103 | ⭐⭐⭐⭐⭐ 优秀 — 但描述的 Package.swift 结构与实际不同 |
| requirements.md | 37 | ⭐⭐ 薄 — 仅 TOC, 无状态矩阵 |
| 各版本 REQ 文件 | 18 文件 | ⭐⭐⭐ 混合 — v0.1-v2.2 详细，但 v1.1-v3.1 全标记"规划中" |
| 实现计划文件 | 4 文件 | ⭐⭐ — 工作指令，非完成文档 |
| 代码级文档注释 | 全项目 | ⭐⭐⭐⭐ 良好 — 每个公开类型/方法都有 /// |

### 7.2 缺失文档

**P0 (必须)**:
- LICENSE 文件 (README 声称 MIT 但文件不存在)
- CHANGELOG.md (17 个版本标签零发布说明)

**P1 (重要)**:
- REQ 状态追踪矩阵 (72 REQs 无实现状态映射)
- 安装指南 (Full Disk Access, LaunchAgent, Homebrew, 常见问题)
- 用户指南 (CLI 全面用法, REPL 命令, 高级查询语法, 过滤器, AI 功能)
- 配置参考 (deepfinder config 所有键)

**P2 (完备)**:
- HTTP API 文档 (GET /search, /stats, /health)
- AppleScript / URL scheme 集成指南
- Man page (deepfinder.1) — REQ-1.0-02 要求
- Shell completions (bash/zsh/fish) — REQ-1.0-02 要求
- 架构决策记录 (ADRs)
- 故障排除 / FAQ

### 7.3 最大问题: 文档与实现脱节

这是信任摧毁级的问题:

1. **CLAUDE.md 第 13 行** ~~说项目是 v0.1.0，76 tests，"Next: v0.2 File system"~~ *(已修复 2026-06-01: CLAUDE.md 现正确显示 v3.0.0)*。实际代码是 v3.0.0，11 个源模块，99+ 源文件，101 个测试文件，1142 tests。
2. **设计 spec** 描述了多 target Package.swift (DeepFinderIndex library, DeepFinderDaemon executable, DeepFinderCLI executable) — 实际是单体 target
3. **所有 v1.1-v3.1 REQ 文件**标记"规划中"，但代码丰富已实现
4. **Sources 目录结构**与 CLAUDE.md 描述的完全不匹配

**任何读 CLAUDE.md 的新贡献者都会被完全误导。**

### 7.4 文档优先级行动

1. **立即**: 修复 CLAUDE.md 状态 (v3.0.0)，更新目录结构，说明单体 target 的现实
2. **立即**: 添加 LICENSE 文件 (MIT)
3. **本周**: 添加 CHANGELOG.md
4. **本周**: 创建 REQ 状态矩阵
5. **本周**: 创建立安装指南
6. **下周**: Man page + shell completions + 用户指南

---

## 八、安全评估

### 8.1 安全风险清单 (按严重度排序)

| 严重度 | 风险 | 详情 | 修复 |
|--------|------|------|------|
| **Critical** | IPC 零认证 | 任何同用户进程可连接 `~/.deep-finder/session/ipc.sock` 发送任意查询/config修改/资源耗尽 payload | 实现 LOCAL_PEERCRED (getsockopt) 验证连接进程身份 |
| **High** | 索引数据库明文 | ~/.deep-finder/cache/index.db 包含用户全部文件路径，WAL/SHM 文件也是明文 | SQLCipher 加密或 sqlite3_key + Keychain 密钥 |
| **High** | 信号处理器延迟安装 | SIGTERM/SIGINT handler 在 daemon live 之后才安装，启动窗口内信号导致无清理残留 | 将 installSignalHandlers() 移至 run() 最开头 |
| **High** | API Key 明文内存 | DeepSeekProvider/QwenProvider 持有 apiKey: String，可能被 core dump 提取 | Keychain 即用即取，ephemeral URLSession |
| **Medium** | PID 文件 TOCTOU | check-then-write 检查已有 daemon 后写 PID 的竞争条件 | 使用 O_EXCL\|O_CREAT + flock 原子创建 |
| **Medium** | IPC 无速率限制 | accept loop 无连接速率控制，恶意进程可耗尽文件描述符 | 添加连接/秒速率限制 + 最大并发连接数 |
| **Medium** | URLSession.shared 用于 AI 请求 | 共享 session 有 cookie 缓存、响应缓存、凭据存储 — 对 Bearer token 请求不必要且有风险 | 使用 URLSessionConfiguration.ephemeral |
| **Low** | SQL LIKE 注入 | deleteRecordsByPathPrefix 不对路径中的 % 和 _ 转义 | 对 LIKE 通配符转义 |
| **Low** | synchronous=NORMAL | SQLite 事务性折中 — 应用崩溃安全但 OS 崩溃可能损坏 | 提供 synchronous=FULL 选项 |

### 8.2 隐私考量

**优势**:
- AI 隐私边界通过类型系统强制执行 (FileMetadataSummary 只含匿名化元数据，无文件内容)
- 所有 AI 功能默认关闭，需手动 opt-in
- API Key 存储在 macOS Keychain (KeychainStore)
- data_preview 函数让用户确认发送内容

**关注**:
- 云端 AI (DeepSeek, Qwen) 涉及跨境数据传输 (中国服务器)
- GDPR/PIPL 合规未明确处理
- 医疗/金融等受监管环境用户需明确文档说明什么数据离境

### 8.3 安全性总体评价

**评分: 6.6/10**

零外部依赖是最大安全优势。但 IPC 无认证和数据库明文是显著差距。守护进程有 Full Disk Access 权限——使其成为高价值攻击目标。开源前最迫切的安全工作是：IPC 认证 + 安全响应流程 (SECURITY.md)。

---

## 九、开源准备度

### 9.1 开源必备文件清单

| 文件 | 状态 | 优先级 |
|------|------|--------|
| README.md | ✅ 已存在 (良好) | — |
| CONTRIBUTING.md | ✅ 已存在 (良好) | — |
| .gitignore | ✅ 已存在 | — |
| LICENSE | ❌ **缺失** (README 声称 MIT) | P0 |
| CHANGELOG.md | ❌ 缺失 | P0 |
| CODE_OF_CONDUCT.md | ❌ 缺失 | P0 |
| SECURITY.md | ❌ 缺失 | P0 |
| .github/ (目录) | ❌ 完全缺失 | P1 |
| .github/workflows/ci.yml | ❌ 缺失 | P1 |
| .github/ISSUE_TEMPLATE/ | ❌ 缺失 | P1 |
| .github/PULL_REQUEST_TEMPLATE.md | ❌ 缺失 | P1 |
| CODEOWNERS | ❌ 缺失 | P1 |
| Makefile | ❌ 缺失 (README 引用 make install) | P1 |
| Homebrew formula | ❌ 缺失 | P2 |
| Man page (deepfinder.1) | ❌ 缺失 | P2 |
| Shell completions | ❌ 缺失 | P2 |
| SUPPORT.md | ❌ 缺失 | P2 |
| FUNDING.yml | ❌ 缺失 | P3 |
| GOVERNANCE.md | ❌ 缺失 | P3 |
| Logo / brand assets | ❌ 缺失 | P3 |

### 9.2 推荐开源协议: MIT License

README 已声明 MIT，这是正确选择。

**选择 MIT 的理由**:
- Swift/Apple 生态系统标准 (Alamofire, Vapor, SwiftLint, Homebrew 自身都用 MIT)
- 最大化采用率 — 宽松，兼容 App Store 分发，仅需保留版权声明
- Apache 2.0 会增加专利条款但加重样板文件负担和贡献者摩擦
- GPL 会阻碍 App Store 分发和嵌入其他工具

**结论**: 坚持 README 已声明的 MIT，创建 LICENSE 文件即可。

### 9.3 社区治理建议

**当前状态**: 单人项目，所有 90 次提交来自同一作者 (Nadav)。无 CODEOWNERS，无维护者团队，无接班人计划。

**建议**:
1. **短期** (开源前): 按模块指定 CODEOWNERS (即使虚拟团队角色)，给贡献者明确的所有权感
2. **中期** (开源后 1-3 月): 从早期贡献者中招募 2-3 名 co-maintainers，授予 commit 权限
3. **治理模型**: 采用 BDFL (Benevolent Dictator for Life) + 维护者团队的轻量模式，适合小项目
4. **决策流程**: 非争议性 PR 由任一 maintainer 审核合并，重大变更需要 2+ approvals 和架构讨论 issue
5. **路线图管理**: 在 GitHub Projects 中公开维护，标注"help wanted"和"good first issue"

### 9.4 分发方案

**主要渠道 (必须)**:
1. **GitHub Releases**: 预编译 arm64 二进制 + SHA256 checksums。需代码签名+公证 (macOS Gatekeeper)
2. **Homebrew**: 创建 homebrew-tap 仓库，Formula 从源码构建 `swift build -c release`

**辅助渠道 (可选)**:
3. **Swift Package Index**: 配置 .spi.yml 自动生成文档
4. **MacPorts**: 作为 Homebrew 替代
5. **直接下载**: 从项目网站提供 pkg 安装器

### 9.5 采纳风险

1. **macOS 26 + M4+ 要求严重限制贡献者基数**: 只有运行最新 macOS 当前代 Apple Silicon 的开发者能构建测试。理智估计这将抑制 80-90% 的潜在贡献者。必须在 README/CONTRIBUTING 中明确记录这一约束的技术原因。

2. **无 CI 意味着无质量门**: 没有自动化测试，所有变更依赖人工审查。对有 1142 测试的项目来说回归风险显著。

3. **Full Disk Access 创建设信任障碍**: 守护进程需要 FDA，这是 macOS 上最高权限之一。无已发布的安全审计、安全策略或第三方验证时，隐私敏感用户会犹豫。

4. **单人维护 Bus Factor = 1**: 如果唯一维护者不可用，项目停滞。必须积极招募共同维护者。

5. **零分发渠道**: 目前唯一安装路径是 `git clone + swift build`。大大减少可寻址用户基础。

6. **AI 功能造成法律模糊**: 云 AI 涉及离设备数据传输。虽说是元数据且 opt-in，但不同司法管辖区 (GDPR, PIPL) 的隐私政策和服务条款影响未处理。

---

## 十、开源行动清单

### P0 — 必须完成，否则不能开源 (预计 7-10 天)

| # | 任务 | 工作量 | 负责角色 | 依赖 |
|---|------|--------|---------|------|
| P0-1 | 创建 LICENSE 文件 (MIT) — 这是法律前提 | 5 min | architect | 无 |
| P0-2 | 创建 SECURITY.md — 漏洞提交流程、响应时间、披露政策 | 1h | architect | 无 |
| P0-3 | 创建 CODE_OF_CONDUCT.md — Contributor Covenant v2.1 | 15 min | architect | 无 |
| P0-4 | 创建 CHANGELOG.md — Keep a Changelog 格式，回溯 17 tags | 2h | architect | git tag history |
| P0-5 | **修复 v1.2 元数据过滤接线** — 将 FilterPipeline 接入搜索流程 | 2-3 days | algo-dev + macos-dev | 需跨 QueryParser, IPCServer, FilterPipeline |
| P0-6 | 设置 GitHub Actions CI — build+test on push/PR | 4h | macos-dev | macOS 26 runner (可能需 self-hosted) |
| P0-7 | **修复 CLAUDE.md 状态** — 更新版本、目录结构、项目阶段、单体 target 说明 | 2h | architect | 需代码库核对 |
| P0-8 | 创建 REQ 状态追踪矩阵 — 72 REQs 的状态、源文件、测试覆盖 | 3h | architect + qa-dev | 需审查所有 REQ 文件和对应源文件 |
| P0-9 | 添加 os_log 结构化日志 — 至少覆盖守护进程关键路径 | 2 days | macos-dev | 需决定日志子系统划分 |

### P1 — 强烈建议，影响社区采纳 (预计 10-14 天)

| # | 任务 | 工作量 | 负责角色 | 依赖 |
|---|------|--------|---------|------|
| P1-1 | 创建 .github/ 目录 + issue templates (bug report, feature request) + PR template | 2h | architect | 无 |
| P1-2 | 创建 CODEOWNERS 文件 — 按模块映射到虚拟团队角色 | 30 min | architect | 无 |
| P1-3 | 创建或删除 Makefile 引用 — README 说 make install 但 Makefile 不存在 | 1h | cli-dev | 无 |
| P1-4 | **完成 XCTest → Swift Testing 迁移** — 8 文件 97 tests (约 2-3 天) | 3 days | qa-dev | 无 |
| P1-5 | 添加 Index 层性能基准 — Trie, FullSubstringMap, TrigramIndex, InMemoryIndex, PinyinIndex | 2 days | algo-dev | P0-5 |
| P1-6 | 添加并发压力测试 — 10-100 并发 IPC 客户端, actor 隔离验证 | 1 day | qa-dev + macos-dev | P0-6 |
| P1-7 | **修复 IPC 认证** — LOCAL_PEERCRED 验证连接进程 | 1 day | macos-dev | 无 |
| P1-8 | 创建安装指南 (docs/INSTALL.md) — Full Disk Access, LaunchAgent, 常见问题 | 2h | cli-dev | 无 |
| P1-9 | **将 Package.swift 拆分为模块化 targets** — DeepFinderIndex, DeepFinderCore 等 | 3 days | architect + macos-dev | P0-5 |
| P1-10 | 创建用户指南 (docs/USER_GUIDE.md) — CLI 全面使用, REPL 命令, 查询语法 | 4h | cli-dev | P0-5 |

### P2 — 锦上添花，后续迭代 (预计 14-21 天)

| # | 任务 | 工作量 | 负责角色 | 依赖 |
|---|------|--------|---------|------|
| P2-1 | 创建 Homebrew formula + man page + shell completions | 2 days | cli-dev + macos-dev | P1-9 |
| P2-2 | **IPC 组帧去重** — 提取共享 IPCFraming.swift | 4h | macos-dev | 无 |
| P2-3 | **审计所有 try? 站点** — 分类并添加日志或将静默改为传递错误 | 2 days | macos-dev + qa-dev | P0-9 |
| P2-4 | **SQLite 加密** — sqlite3_key + Keychain 密钥 | 1 day | macos-dev | 无 |
| P2-5 | 创建 HTTP API 文档 (docs/API.md) | 2h | macos-dev | 无 |
| P2-6 | 创建 AppleScript / URL scheme 集成指南 (docs/INTEGRATIONS.md) | 2h | cli-dev + ai-dev | 无 |
| P2-7 | 创建架构决策记录 (docs/adr/) — 5-10 个关键决策 | 4h | architect | 无 |
| P2-8 | **修复 PID 文件 TOCTOU** — O_EXCL\|O_CREAT + flock | 2h | macos-dev | 无 |
| P2-9 | 创建 SUPPORT.md — 问题求助渠道 | 15 min | architect | 无 |
| P2-10 | 添加 IPC 速率限制 — 连接/秒 + 最大并发连接数 | 2h | macos-dev | P1-7 |
| P2-11 | **替换 DaemonMain 100ms 轮询** — AsyncStream/continuation | 2h | macos-dev | 无 |
| P2-12 | 消除共享代码重复 — DateFormatter, JSONEncoder/Decoder 缓存, expandTilde, maxMessageSize | 4h | algo-dev + cli-dev | 无 |
| P2-13 | 添加 GUI 首次启动引导流程 + 错误状态处理 | 3 days | ui-dev | 无 |
| P2-14 | 配置 Swift Package Index (.spi.yml) + 覆盖率工具 + .xctestplan | 2h | qa-dev | P1-9 |
| P2-15 | 创建 GOVERNANCE.md + FUNDING.yml | 1h | architect | 无 |
| P2-16 | 设计项目 Logo 和品牌资产 | 1 day | ui-dev | 无 |
| P2-17 | 提供 GitHub Release 预编译 arm64 二进制 + 公证 | 1 day | macos-dev | P2-1 |
| P2-18 | 创建版本发布检查点文档 (docs/releases/) | 4h | architect | 无 |

---

## 十一、补充功能建议

以下是从开源社区竞争角度出发的功能建议，可在未来版本规划中考虑:

### 11.1 差异化功能 (利用 DeepFinder 独特架构优势)

1. **本地语义搜索 (v3.1 RAG 加速)**: 这是真正差异化的杀手功能。无其他 macOS 搜索工具提供端侧、私密的语义搜索。即使只有基础版的原型（CoreML 嵌入 + 余弦相似度最近邻），也可作为核心亮点。

2. **隐私仪表盘**: 一个可视化面板显示"本次会话发送给云端的内容: [空] — 所有搜索完全本地"。透明化隐私承诺，建立用户信任。

3. **搜索工作流自动化**: 允许用户定义"找到匹配 X 的文件 → 自动执行 Y 操作"的规则，利用 DeepFinder 的实时 FSEvent 监视为触发器。这超越文件搜索进入自动化领域。

### 11.2 社区友好功能

4. **插件系统**: 允许社区贡献新的 SearchProvider (如搜索 Git repos, 搜索 Docker 容器, 搜索 npm 包)。现有协议已有正确接口，只需文档和分发机制。

5. **主题系统**: 允许社区创建和分享 GUI 主题 (基于 SwiftUI 的 modifier 链)。终端用户喜欢个性化。

6. **多语言界面**: 直接支持中英双语外，准备 i18n 基础设施让社区贡献翻译。

7. **基准测试排行榜**: 在 GitHub Pages 上设置一个性能基准仪表盘，自动跟踪 100K/500K/1M 文件的索引时间和查询延迟。这对于一个"速度为最高优先级"的项目来说既是透明度也是营销。

### 11.3 商业化/可持续性考量

8. **Pro 版本**: CLI 免费开源 (MIT)，GUI 高级功能按月订阅。类似 Rectangle (免费) vs Rectangle Pro (付费) 的模式在 macOS 工具生态中表现良好。

9. **团队版**: 为 IT 团队提供集中管理的部署方案 (MDM profile)，是可能的收入来源。

---

## 十二、总结与建议

### 12.1 总体判决

**DeepFinder v3.0.0 是一个技术上令人印象深刻的 solo 开发者项目**，具有强大的架构、创新的 AI 功能（本地 Vision/Speech，隐私优先云 AI），以及 973 个通过的测试。代码质量、并发模型、内联文档质量和架构一致性都达到了高标准。

**然而，该项目目前尚未达到开源就绪状态。** 三个关键阻塞项:

1. **无 LICENSE 文件** — 法律上不能开源
2. **无 CI/CD** — 无自动化质量门
3. **v1.2 元数据过滤未接线** — 核心功能缺陷，高级用户首次尝试即会放弃

此外，文档与实现之间的严重脱节是一个信任问题——任何潜在贡献者读 CLAUDE.md 都会被误导。

### 12.2 关键风险

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| macOS 26 限制贡献者基数为零 | 极高 | 高 | 文档化技术原因，接受小社区现实 |
| 无 CI 导致回归未被发现 | 高 | 高 | 优先 P0-6 |
| 单人维护 Bus Factor | 中 | 极高 | 开源后积极招募 co-maintainers |
| Full Disk Access 引起信任顾虑 | 中 | 中 | 安全审计 + SECURITY.md + 隐私仪表盘 |
| AI 云功能法律合规 | 低-中 | 中 | 明确数据离境文档，metadata-only 可验证 |

### 12.3 推荐开源时间线

```
Week 1-2:  P0 items (LICENSE, SECURITY, CODE_OF_CONDUCT, CHANGELOG,
           CLAUDE.md fix, REQ matrix, v1.2 filter wiring)
Week 3:    CI setup + os_log integration + IPC auth fix
Week 4:    CRITICAL: v1.2 filter fix验证 + 内部测试
Week 5:    P1 items (issue/PR templates, XCTest migration,
           Index benchmarks, Install Guide)
Week 6:    P1 continued (Package.swift split, User Guide, stress tests)
Week 7-8:  P2 items (Homebrew, man page, ADRs, onboarding, etc.)
Week 9:    公开发布 — GitHub public + Hacker News Show HN + 社区公告
```

**最快安全开源时间**: ~4 周（仅 P0）
**推荐完整开源时间**: ~8-9 周（P0 + P1 + 关键 P2）

### 12.4 最后的话

DeepFinder 的代码基础很强。问题不在于代码质量——问题在于开源基础设施。修复 LICENSE/SECURITY/CI 后，这个项目有实力在 macOS 文件搜索领域占据一个独特位置：为重视隐私的 macOS 高级用户提供 Everything 级别的即时搜索，同时具有 AI 增强功能，既尊重数据主权，又提供真正的实用价值。

但现在打开仓库，第一个看到的是没有 LICENSE 且 CLAUDE.md 说项目是 v0.1.0。先修复这些——再开源。