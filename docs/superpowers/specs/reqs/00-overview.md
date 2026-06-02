# DeepFinder — 需求管理

需求 ID 格式：`REQ-{版本}-{序号}`，如 `REQ-1.0-01`。
优先级：P0 必须 / P1 重要 / P2 增强 / P3 未来。
状态：📋 规划中 / 🔨 开发中 / ✅ 已完成 / ❌ 已取消。
执行方式：🖥️ 本地 / ☁️ 云端 / 🖥️☁️ 混合。

详细架构设计见 `../2026-05-26-deep-finder-design.md`。

---

## 模块文件索引

| 文件 | 版本 | REQ 范围 | 说明 |
|------|------|----------|------|
| [v0.1-index-core.md](v0.1-index-core.md) | v0.1 | REQ-0.1-01 ~ 07 | 索引核心：FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex |
| [v0.2-file-system.md](v0.2-file-system.md) | v0.2 | REQ-0.2-01 ~ 05 | 文件系统：FSEventStream, FileScanner, FSEventWatcher, IndexPersistence, 索引恢复 |
| [v0.3-search.md](v0.3-search.md) | v0.3 | REQ-0.3-01 ~ 05 | 搜索：SearchProvider, SearchQuery/SearchResult, SearchCoordinator, 排序策略, 性能基准 |
| [v0.4-daemon-ipc.md](v0.4-daemon-ipc.md) | v0.4 | REQ-0.4-01 ~ 05 | Daemon + IPC：DaemonMain, IPCServer, IPCProtocol, 生命周期管理, ConfigStore |
| [v0.5-cli-singleshot.md](v0.5-cli-singleshot.md) | v0.5 | REQ-0.5-01 ~ 04 | CLI Single-Shot：CLIMain, TerminalFormatter, IPCClient, 参数解析 |
| [v0.6-repl.md](v0.6-repl.md) | v0.6 | REQ-0.6-01 ~ 03 | Interactive REPL：REPL 循环, REPL 命令, 历史与导航 |
| [v0.7-daemon-mgmt.md](v0.7-daemon-mgmt.md) | v0.7 | REQ-0.7-01 ~ 03 | Daemon 管理：daemon 子命令, config 子命令, install 子命令 |
| [v1.0-cli-release.md](v1.0-cli-release.md) | v1.0 | REQ-1.0-01 ~ 04 | CLI Release：集成测试, 打包, 模糊纠错, ANSI 高亮 |
| [v1.1-advanced-syntax.md](v1.1-advanced-syntax.md) | v1.1 | REQ-1.1-01 ~ 07 | 高级搜索语法 |
| [v1.2-metadata-filter.md](v1.2-metadata-filter.md) | v1.2 | REQ-1.2-01 ~ 08 | 元数据过滤 |
| [v1.3-search-exp.md](v1.3-search-exp.md) | v1.3 | REQ-1.3-01 ~ 07 | 搜索体验 |
| [v1.4-content-search.md](v1.4-content-search.md) | v1.4 | REQ-1.4-01 ~ 04 | 内容搜索 |
| [v1.5-duplicate.md](v1.5-duplicate.md) | v1.5 | REQ-1.5-01 ~ 06 | 重复查找 |
| [v2.0-gui.md](v2.0-gui.md) | v2.0 | REQ-2.0-01 ~ 13 | GUI + 扩展索引：SearchPanel, SearchBar, ResultsList, GlobalHotkey, Settings |
| [v2.1-media-metadata.md](v2.1-media-metadata.md) | v2.1 | REQ-2.1-01 ~ 07 | 媒体元数据：图片/音频/视频/PDF |
| [v2.2-service-integration.md](v2.2-service-integration.md) | v2.2 | REQ-2.2-01 ~ 05 | 服务集成：HTTP/URL Scheme/Shortcuts/AppleScript |
| [v3.0-ai.md](v3.0-ai.md) | v3.0 | REQ-3.0-01 ~ 16 | AI 辅助搜索 |
| [v3.1-rag.md](v3.1-rag.md) | v3.1 | REQ-3.1-01 ~ 07 | 本地 RAG |

---

## 版本路线图

| Version | Milestone | Key Features |
|---------|-----------|-------------|
| `v0.1` | Index core | FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex |
| `v0.2` | File system | FSEventStream, FileScanner, FSEventWatcher, IndexPersistence |
| `v0.3` | Search | SearchProvider protocol, SearchCoordinator (plain actor), benchmarks |
| `v0.4` | Daemon + IPC | DaemonMain, IPCServer (Unix socket + JSON), PID 管理, LaunchAgent |
| `v0.5` | CLI single-shot | 参数解析, TerminalFormatter (ANSI), --json/--0/--sort/--limit |
| `v0.6` | Interactive REPL | readline 循环, :help/:stats/:open/:reveal, 历史持久化 |
| `v0.7` | Daemon 管理 | daemon start/stop/restart/install, config get/set |
| **`v1.0`** | **CLI Release** | 完整可用 CLI：daemon + REPL + single-shot + Homebrew formula + man page + shell completions |
| `v1.1` | 高级语法 | 布尔/通配符/正则/路径限定/修饰符/搜索历史 |
| `v1.2` | 元数据过滤 | size/date/ext/type 过滤 |
| `v1.3` | 搜索体验 | 书签/自定义过滤器/排序/搜索建议 |
| `v1.4` | 内容搜索 | content: 函数, 编码支持, 行号定位 |
| `v1.5` | 重复查找 | dupe/sizedupe/hashdupe/empty/childcount |
| **`v2.0`** | **GUI + 扩展索引** | NSPanel + Liquid Glass + Apple Intelligence glow + 全局热键 (⌃⌘K) + 外置卷/网络卷 |
| `v2.1` | 媒体元数据 | 图片尺寸/音频标签/视频信息/PDF 元数据 |
| `v2.2` | 服务集成 | HTTP 搜索/URL Scheme/Shortcuts/AppleScript |
| `v3.0` | AI 语义 | 语义搜索/智能建议/内容理解/智能分类 |
| `v3.1` | 本地 RAG | 文件分块/Embedding/向量索引/语义检索/本地生成 |

---

## 需求统计

| 版本 | P0 | P1 | P2 | P3 | 合计 |
|------|----|----|----|----|------|
| v0.1 | 7 | 0 | 0 | 0 | 7 |
| v0.2 | 4 | 1 | 0 | 0 | 5 |
| v0.3 | 4 | 1 | 0 | 0 | 5 |
| v0.4 | 4 | 1 | 0 | 0 | 5 |
| v0.5 | 4 | 0 | 0 | 0 | 4 |
| v0.6 | 2 | 1 | 0 | 0 | 3 |
| v0.7 | 1 | 2 | 0 | 0 | 3 |
| v1.0 | 2 | 2 | 0 | 0 | 4 |
| v1.1 | 6 | 1 | 0 | 0 | 7 |
| v1.2 | 7 | 1 | 0 | 0 | 8 |
| v1.3 | 5 | 2 | 0 | 0 | 7 |
| v1.4 | 3 | 1 | 0 | 0 | 4 |
| v1.5 | 5 | 1 | 0 | 0 | 6 |
| v2.0 | 7 | 5 | 1 | 0 | 13 |
| v2.1 | 4 | 3 | 0 | 0 | 7 |
| v2.2 | 2 | 2 | 1 | 0 | 5 |
| v3.0 | 4 | 8 | 4 | 0 | 16 |
| v3.1 | 4 | 3 | 0 | 0 | 7 |
| **合计** | **75** | **35** | **6** | **0** | **116** |

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-05-29 | v1.0 | 初始需求列表，107 项 |
| 2026-05-29 | v1.1 | v0.1-v1.0 需求补充用户场景、操作流程、验收标准。改用结构化需求卡格式 |
| 2026-05-29 | v2.0 | CLI-first 重构：v0.4 (Daemon+IPC), v0.5 (CLI single-shot), v0.6 (REPL), v0.7 (daemon 管理)。v1.0 改为 CLI Release。旧 v0.4-v0.5 UI REQs 迁移至 v2.0。v3.0/v3.1 AI REQs 更新 CLI 上下文。72 项 REQ |
| 2026-05-29 | v2.1 | 拆分 monolithic requirements.md 为 per-module 文件。原文件替换为索引 |
| 2026-06-02 | v3.0 | 补充 v1.1-v1.5 和 v2.1-v2.2 统计。总计从 72 更正为 116 项 REQ |
