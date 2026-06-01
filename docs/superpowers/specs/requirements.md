# DeepFinder — 需求管理

Status: See REQ_STATUS.md for the implementation status of all requirements.

需求 ID 格式：`REQ-{版本}-{序号}`，如 `REQ-1.0-01`。
优先级：P0 必须 / P1 重要 / P2 增强 / P3 未来。
状态：📋 规划中 / 🔨 开发中 / ✅ 已完成 / ❌ 已取消。
执行方式：🖥️ 本地 / ☁️ 云端 / 🖥️☁️ 混合。

详细架构设计见 `2026-05-26-deep-finder-design.md`。

---

## 需求文件

需求已拆分为 per-module 文件，位于 `reqs/` 目录：

| 文件 | 版本 | 说明 |
|------|------|------|
| [`reqs/00-overview.md`](reqs/00-overview.md) | 全局 | 格式定义、版本路线图、需求统计、变更日志 |
| [`reqs/v0.1-index-core.md`](reqs/v0.1-index-core.md) | v0.1 | 索引核心 (7 REQ) |
| [`reqs/v0.2-file-system.md`](reqs/v0.2-file-system.md) | v0.2 | 文件系统 (5 REQ) |
| [`reqs/v0.3-search.md`](reqs/v0.3-search.md) | v0.3 | 搜索 (5 REQ) |
| [`reqs/v0.4-daemon-ipc.md`](reqs/v0.4-daemon-ipc.md) | v0.4 | Daemon + IPC (5 REQ) |
| [`reqs/v0.5-cli-singleshot.md`](reqs/v0.5-cli-singleshot.md) | v0.5 | CLI Single-Shot (4 REQ) |
| [`reqs/v0.6-repl.md`](reqs/v0.6-repl.md) | v0.6 | Interactive REPL (3 REQ) |
| [`reqs/v0.7-daemon-mgmt.md`](reqs/v0.7-daemon-mgmt.md) | v0.7 | Daemon 管理 (3 REQ) |
| [`reqs/v1.0-cli-release.md`](reqs/v1.0-cli-release.md) | v1.0 | CLI Release (4 REQ) |
| [`reqs/v1.1-advanced-syntax.md`](reqs/v1.1-advanced-syntax.md) | v1.1 | 高级搜索语法 (待补充) |
| [`reqs/v1.2-metadata-filter.md`](reqs/v1.2-metadata-filter.md) | v1.2 | 元数据过滤 (待补充) |
| [`reqs/v1.3-search-exp.md`](reqs/v1.3-search-exp.md) | v1.3 | 搜索体验 (待补充) |
| [`reqs/v1.4-content-search.md`](reqs/v1.4-content-search.md) | v1.4 | 内容搜索 (待补充) |
| [`reqs/v1.5-duplicate.md`](reqs/v1.5-duplicate.md) | v1.5 | 重复查找 (待补充) |
| [`reqs/v2.0-gui.md`](reqs/v2.0-gui.md) | v2.0 | GUI + 扩展索引 (13 REQ) |
| [`reqs/v3.0-ai.md`](reqs/v3.0-ai.md) | v3.0 | AI 辅助搜索 (16 REQ) |
| [`reqs/v3.1-rag.md`](reqs/v3.1-rag.md) | v3.1 | 本地 RAG (7 REQ) |

**合计**：72 项 REQ（P0: 44, P1: 24, P2: 5）。详见 [`reqs/00-overview.md`](reqs/00-overview.md)。
