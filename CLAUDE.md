# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

DeepFinder — a macOS file search app rivaling Windows Everything. **v1.0 = CLI-first** (daemon + interactive REPL + single-shot), v2.0 adds GUI. Apple Silicon M4+ only, arm64, minimum macOS 26 (Tahoe). **Speed is the #1 priority — memory and CPU are not constraints.**

**Organization**: nadav.com.cn

**产品名配置**：`PRODUCT.toml` 是产品名的唯一来源。代码中通过 `Product` enum（`Sources/Index/ProductConfig.swift`）引用。改产品名只改 `PRODUCT.toml` + `ProductConfig.swift`，不散落到其他文件。文档中用显示名 "DeepFinder" 即可。

**Status**: `v3.0.0` ✅ **完成** — CLI + daemon + GUI + AI semantic search + media metadata + services. Full roadmap v0.1 through v3.0 complete. Spec: `docs/superpowers/specs/`. OSS readiness assessment: `docs/superpowers/plans/2026-05-31-oss-readiness-assessment.md`.

Zero external dependencies — pure Swift + Apple frameworks only (Foundation, CoreServices, Carbon, SQLite3). CLI via Darwin.readline + ANSI escape codes.

## Build & Test

Requires **swift-tools-version ≥ 6.2** (needed for `.macOS(.v26)` platform specifier).

```bash
swift build                              # Build all targets
swift test                               # Run all tests
swift test --filter TrieTests            # Run single test suite
swift run deepfinder "query"             # CLI single-shot (after v0.5)
swift run deepfinder                     # CLI interactive REPL (after v0.6)
```

## Version Roadmap

渐进式开发，每个版本独立可用。详细功能清单见 `docs/superpowers/specs/2026-05-26-deep-finder-design.md` §功能路线图。

| Version | Milestone | Status |
|---------|-----------|--------|
| `v0.1`–`v0.7` | Index → FS → Search → Daemon+IPC → CLI | ✅ 完成并打标签 |
| `v1.0` | **CLI Release** | ✅ 完成并打标签 |
| `v1.1`–`v1.5` | 高级语法/元数据过滤/搜索体验/内容搜索/重复查找 | ✅ 完成并打标签 |
| **`v2.0`** | **GUI + 扩展索引** | ✅ Liquid Glass + 全局热键 + 外置卷 |
| `v2.1` | 媒体元数据 | ✅ 完成并打标签 |
| `v2.2` | 服务集成 | ✅ 完成并打标签 |
| **`v3.0`** | **AI 语义** | ✅ 完成 |

**Workflow**: Each version develops on its `dev/vX.Y` branch. When deliverables pass all tests and review, merge to `main` and tag `vX.Y.Z`. Next version branches from `main`.

**Version file**: `VERSION` at repo root — single line, e.g. `0.1.0-dev`. Bump on milestone completion.

## Development Workflow

### Spec-first

All changes start in `docs/superpowers/specs/` before touching code. When a requirement changes:
1. Update the relevant spec file in `docs/superpowers/specs/`
2. Review the spec change for consistency with the rest of the spec
3. Then implement the code change to match the updated spec

Never modify code to introduce behavior that isn't reflected in the spec, and never leave a spec out of sync with the implementation.

### Test-first (TDD)

**Write tests before implementation.** For every new component:

1. **Write failing test** — 定义期望行为（接口、边界条件、错误路径）
2. **Implement minimum code** — 让测试通过
3. **Refactor** — 保持测试绿色，清理实现

具体要求：
- 每个新 struct/class/actor/enum 必须有对应的测试文件
- 测试命名描述行为：`testInsertIncreasesCount`，不写 `testTrie1`
- 测试覆盖：正常路径 + 边界条件 + 错误路径
- 性能敏感组件（Trie、FullSubstringMap 等）必须包含 `measure` block 基准测试
- 测试先行不是可选项 — 没有 failing test 不写实现代码

### Feature → Review Cycle

**每完成一个小功能，立即代码检视。** 不积累大量未检视代码。

小功能定义：一个可独立测试的最小交付单元，如：
- 一个 struct/class 的完整实现 + 测试
- 一个协议的实现
- 一个模块的子功能

流程：
```
spec 更新 → 写 failing test → 实现 → 测试绿色 → 代码检视 → 修复检视问题 → 提交
```

检视触发时机：
- 新文件创建后
- 现有文件行为变更后
- 一个 REQ item 实现完成后
- 绝不在版本结束时才统一检视

### Code Review — 两轮会审制

一轮（发现问题）：全员会审，按角色分配检视视角（architect/algo-dev/macos-dev/cli-dev/qa-dev/researcher）。每个 finding 必须有具体证据（文件路径、行号、实际行为）。不限流的成员直接完成，限流的由 lead 补上该视角。产出：问题清单（严重/重要/补充）。

二轮（验证问题）：对每个 finding 用网络搜索交叉验证，确认事实正确性。标注每个 finding 为 confirmed（确认修复）/ refuted（推翻）/ already_fixed（已修复）/ deferred（延期）。产出：确认修复清单。

三轮（修复+验证）：按优先级执行修复，修复后运行测试验证。No speculation without evidence.

**批量检视**（如版本级 spec 变更）用 workflow 多 agent 并行。日常小功能检视用单个 `code-reviewer` agent 即可。

## Context Management

- **主动压缩上下文**：对话接近 85% 上下文窗口时，主动触发 `/compact` 或精简输出。不要等到自动压缩 — 在信息密度下降时就行动。
- **Workflow 优先**：需要多 agent 并行、多阶段编排、或大规模扫描时，优先使用 Workflow 工具（`pipeline`/`parallel`/`phase`），而非手动逐个调度 Agent。Workflow 提供确定性控制流、进度可视化、自动缓存复用。
- **精简输出**：长对话中避免重复已知信息、大段引用文件内容。给出结论 + 关键路径，需要详情时再用 Read/Grep 按需获取。

## Agent Resilience

When subagents (Agent tool, Workflow agents) encounter API rate limits (HTTP 429), throttling errors, or transient failures:
- **Auto-retry with backoff**: Pause 10 seconds, then retry. Do not surface the error to the user unless 3 consecutive retries fail.
- **Graceful degradation**: If a specific agent or tool is rate-limited, continue with the remaining agents/tools that are still available. Report what was skipped.
- **Never halt on transient errors**: Rate limits are temporary. Do not treat them as task failures. Log the delay and continue.

## Gotchas

- **Full Disk Access**: FSEvents can't monitor all directories without Full Disk Access. Without it, ~/Documents, ~/Desktop, ~/Downloads silently skipped.
- **Not sandboxable**: Needs Full Disk Access. Cannot go on Mac App Store. Distributed via GitHub Releases + Homebrew formula.
- **Daemon lifecycle**: CLI auto-starts daemon on first query. LaunchAgent optional for auto-start on login. Daemon crash = CLI reconnects after restart.
- **Socket cleanup**: If daemon crashes without cleanup, stale socket file at `~/.deep-finder/ipc.sock` must be removed before restart. PID file check handles this.
- **v2.0 GUI notes**: LSUIElement menu bar app, global hotkey (⌃⌘K) requires Accessibility permission, no Dock icon — debug via Xcode attach-to-process.

## Directory Structure

```
Sources/
  CLIEntry/                  # CLI executable entry point (main.swift)
  DaemonEntry/               # Daemon executable entry point (main.swift)
  Index/                      # FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex
  Search/                     # SearchProvider, SearchCoordinator, SearchQuery, SearchResult, FilterPipeline, SearchSorter, ContentScanner
  FS/                         # FileSystemEventStream, FileScanner, FSEventWatcher, MockEventStream, VolumeManager
  Persist/                    # IndexPersistence (SQLite WAL), IndexRecovery
  Daemon/                     # DaemonMain, IPCServer, IPCProtocol, IPCClient, ConfigStore, LaunchAgent
  CLI/                        # CLIMain, ArgParser, SingleShot, REPL, TerminalFormatter, ConfigCommands, DaemonCommands, InstallCommands
  GUI/                        # SearchPanelView, SearchBarView, ResultsListView, SearchViewModel, AppDelegate, GlobalHotkey, IntelligenceGlow, GlassEffectContainer, OnboardingView, QuickLookPreview, SettingsView, StatusBarController, SpeechOverlayView
  AI/                         # AIConfig, AIContext, AIModelProvider, AnthropicProvider, ClipboardSearch, CloudEmbeddingProvider, CrossLanguageSearch, DeepSeekProvider, EmbeddingProvider, FileMetadataSummary, GeminiProvider, HTTPClient, ImageSimilaritySearch, KeychainStore, LocalSpeechProvider, LocalVisionProvider, MatchExplainer, NLEmbeddingProvider, NLOperations, NLSearchTranslator, PromptLoader, Prompts/, ProviderRegistry, QwenProvider, ResultSummarizer, SearchAdvisor, SemanticGrouper, SpeechAuthorization, VectorStore, VisionTaggingCoordinator
  Media/                      # ImageMetadataExtractor, AudioMetadataExtractor, VideoMetadataExtractor, PDFMetadataExtractor, MediaMetadataIndex
  Services/                   # HTTPSearchService, URLSchemeHandler, SearchIntent, SearchScriptCommand
Tests/
  IndexTests/ SearchTests/ FSTests/ PersistTests/ DaemonTests/ CLITests/ GUITests/ AITests/ MediaTests/ ServicesTests/
docs/
  superpowers/specs/          # requirements.md (index → reqs/), architecture design doc
  superpowers/plans/          # implementation plans, OSS readiness assessment
Package.swift                 # Single monolithic DeepFinder library target (split into sub-libraries planned)
VERSION                       # Current: 3.0.0
```

## Architecture

**Data flow (v1.0 CLI):** `deepfinder` CLI → Unix domain socket IPC → Daemon → SearchCoordinator → SearchProvider (AsyncSequence) → InMemoryIndex (actor) → results

**Data flow (v2.0 GUI, same daemon):** Global Hotkey → SearchPanel (NSPanel) → IPC → same Daemon → results

**Dependency direction (one-way, no cycles):**
```
CLI/Daemon → Search → Index
  └→ IPC
(v2.0: GUI → IPC → Daemon, same daemon binary)
```

Index layer has zero UI/CLI dependencies and can be tested in isolation.

**Package.swift targets:**
- `DeepFinder` (library) — all modules at path `Sources/` (excludes CLIEntry/, DaemonEntry/)
- `DeepFinderCLI` (executable) — CLI entry point, depends on DeepFinder, path `Sources/CLIEntry/`
- `DeepFinderDaemon` (executable) — daemon entry point, depends on DeepFinder, path `Sources/DaemonEntry/`
- `DeepFinderTests` (test target) — depends on `DeepFinder`, path `Tests/`

**Concurrency model:**
- `InMemoryIndex`: actor — all read/write via actor isolation
- `IndexingEngine`: actor — coordinates FileScanner + FSEventWatcher
- `SearchCoordinator`: plain actor (NOT @MainActor) — works in both daemon and future GUI contexts

**Key design decisions:**
- **Daemon + thin CLI (Everything model)**: Background daemon holds full in-memory index. CLI is a ~1ms thin client connecting via Unix socket. Sub-millisecond query latency because indexing is done once at startup.
- **IPC protocol**: Unix domain socket at `~/.deep-finder/ipc.sock`, 4-byte length prefix + JSON body. Codable-native. Debuggable via `nc -U`.
- **CLI modes**: Single-shot (`deepfinder "query"`) and interactive REPL (`deepfinder` with no args). Manual `CommandLine.arguments` parsing (zero external deps).
- **REPL**: Darwin.readline (libedit) for prompt, history, tab-completion. Commands: :help, :quit, :stats, :config, :daemon, :open N, :reveal N.
- **Terminal output**: ANSI escape codes, `isatty()` auto-disables colors when piped. --json and --0 for scripting.
- **SearchProvider protocol**: Returns `AsyncSequence<SearchResult, Never>`. MVP's in-memory index yields all results at once, but interface supports future streaming (AI, content search). `cancel(queryID:)` for cancellation.
- **InMemoryIndex (actor)**: Speed over memory (M4+ unified memory). Index structures:
  - Trie: O(k) prefix matching, Unicode scalar granularity
  - FullSubstringMap: all substrings → FileRecord.ID for names ≤64 chars, O(1) lookup
  - TrigramIndex: trigram → posting list for names >64 chars (rare fallback)
  - PinyinIndex: CFStringTokenizer → pinyin tokens in a Trie for Chinese filename search
- **Unicode**: All filenames NFC-normalized on ingestion (`precomposedStringWithCanonicalMapping`). Queries normalized the same way.
- **Persistence**: SQLite WAL at `~/.deep-finder/index.db` (permissions 600). Stores FileRecord[], rebuilds index structures in memory on startup (<1s on M4). Batch writes every 5s or 100 changes.
- **FSEvents**: Abstracted behind `FileSystemEventStream` protocol. Production wraps FSEventStreamCreate, tests use MockEventStream.
- **Index state machine**: stale → verifying → live. CLI displays state via `:stats` command.

**v2.0 GUI additions**: NSPanel + Liquid Glass (`.glassEffect()`), Apple Intelligence glow (AngularGradient teal/violet/coral/amber rotating ~1.8s, 60fps), global hotkey (⌃⌘K via RegisterEventHotKey + CGEventTap fallback). Same daemon serves both CLI and GUI via IPC.

**Search behavior**: Case-insensitive by default (preserves original case for display). NFC normalized. Paginated results (100 per page). No debounce for in-memory queries. External and network volumes indexed (removed on unmount).

**Exit codes**: 0=success, 1=no results, 2=daemon error, 3=query error, 4=argument error.

**Daemon lifecycle**: LaunchAgent (launchd plist in ~/Library/LaunchAgents/). Auto-started by CLI if not running. PID file at `~/.deep-finder/daemon.pid`. SIGTERM handler: flush SQLite + save FSEvents cursor + remove socket + exit.

## Team

虚拟团队，Claude 启动时按需激活对应角色的 subagent。每个角色对应一个专业视角，通过 Agent tool 的 `subagent_type` 或系统提示注入角色上下文。

| 角色 | Agent 名称 | 职责 | 负责模块 |
|------|-----------|------|----------|
| **架构师** | `architect` | 技术决策、spec 维护、代码检视、版本规划、二轮确认 | 全局 |
| **算法工程师** | `algo-dev` | 数据结构实现、搜索语法解析、性能优化、基准测试 | Index (Trie/FullSubstringMap/TrigramIndex/PinyinIndex), Search 语法 |
| **macOS 工程师** | `macos-dev` | FSEvents、SQLite WAL、LaunchAgent、权限模型、打包分发、Unix socket IPC | IndexingEngine, IndexPersistence, DaemonMain, IPCServer |
| **CLI 工程师** | `cli-dev` | CLI 参数解析、REPL 交互、终端格式化、ANSI 颜色、readline | DeepFinderCLI: CLIMain, REPL, TerminalFormatter, IPCClient |
| **UI 工程师** | `ui-dev` | SwiftUI 动画、Liquid Glass、无障碍、键盘交互、Quick Look (v2.0) | SearchPanel, IntelligenceGlow, ResultRowView, Settings |
| **AI 工程师** | `ai-dev` | CoreML、Vision、LLM API、向量索引、RAG pipeline、隐私边界 | AI/, v3.0-v3.1 |
| **测试工程师** | `qa-dev` | 单元测试、性能基准、边界条件、集成测试、回归测试 | Fixtures, *Tests, DaemonTests, CLITests |
| **信息顾问** | `researcher` | 查询网络最新信息、验证技术事实、调研竞品和最佳实践。**所有成员有问题都可以找他帮忙** | 全局支持 |

### 使用方式

开发任务时，按模块分配给对应角色的 subagent。角色名（如 `architect`）用于语义上下文注入，实际 agent 类型用 `general-purpose` 或 `feature-dev:*` 等内置类型：

```
# TDD 流程示例：实现 Trie
1. 写 failing test → TrieTests.swift
2. 实现 Trie.swift → 测试绿色
3. 代码检视（小功能完成后立即触发）
Agent("检视 Trie 实现：正确性、边界条件、Unicode 处理", subagent_type="code-reviewer", name="architect")

# 实现 FSEvents 监听
Agent("实现 FSEventWatcher", subagent_type="general-purpose", name="macos-dev")

# 实现 CLI REPL
Agent("实现 REPL 交互循环", subagent_type="general-purpose", name="cli-dev")
```

当前阶段（v3.0）所有团队角色均已激活：**algo-dev**、**architect**、**researcher**、**macos-dev**、**cli-dev**、**ui-dev**、**ai-dev**、**qa-dev**。新功能按模块分配给对应角色的 subagent。

### 信息顾问使用场景

其他成员遇到以下情况时，激活 researcher 查询最新信息：
- API 是否已废弃（如 NSScreen.main 状态确认）
- 最佳实践和性能数据（如 Swift Dict 内存开销）
- 新框架用法（如 macOS 26 Liquid Glass API 细节）
- 竞品功能对比（如 Everything 1.5 新功能）
- 安全漏洞和修复方案（如 SQLite WAL 已知问题）

## Reference

Full architecture spec: `docs/superpowers/specs/2026-05-26-deep-finder-design.md`
