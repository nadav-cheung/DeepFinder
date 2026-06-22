# 需求变更日志 (Requirements Change Log)

每个需求变更必须在此记录。变更发生后同步更新受影响的 REQ 文件、设计文档和 CLAUDE.md。

格式：
- **变更 ID**: `CHG-YYYY-MM-DD-NN`
- **来源**: 变更提出者/触发原因
- **影响 REQ**: 受影响的 REQ 编号
- **影响文档**: 需要更新的文档清单
- **变更类型**: 新增 / 修改 / 废除 / 澄清

---

## 2026-06-03 — 审计纠正与竞品信息更新

### CHG-2026-06-03-01: API Key 存储方案确认 — 不使用 macOS Keychain

- **来源**: nadav（项目 owner）
- **影响 REQ**: REQ-3.0-15 (AI 配置管理)
- **影响文档**:
  - `docs/explanation/privacy-model.md` — 修正密钥存储描述，不声称使用 Keychain
  - `docs/explanation/security-whitepaper.md` — 记录 .env (600) 方案
  - `docs/superpowers/plans/2026-06-03-keychain-migration.md` — 取消该计划
- **变更类型**: 废除
- **描述**: API keys (Anthropic, DeepSeek, Qwen, Gemini) 继续使用 `~/.deep-finder/.env` (permissions 600) 存储，不迁移到 macOS Keychain。当前方案已足够安全（本地文件，仅 owner 可读写）。文档中应如实描述此方案，不得声称使用 Keychain。
- **影响**: 删除 Keychain 迁移计划。安全白皮书改为描述 .env 600 方案。隐私模型文档修正。

### CHG-2026-06-03-02: macOS 26 (Tahoe) 已发布 — 平台目标确认

- **来源**: 网络验证（nadav）
- **影响 REQ**: REQ-2.0-01 (平台目标), REQ-2.0-14~18 (打包分发)
- **影响文档**:
  - `docs/superpowers/specs/design/2026-05-26-deep-finder-design.md` — 确认平台目标正确
  - `docs/explanation/macos-compatibility.md` — 从「紧急回移植」改为「评估向下兼容价值」
  - `CLAUDE.md` — 确认 macOS 26 平台目标
  - `docs/superpowers/plans/2026-05-31-oss-readiness-assessment.md` — 审查平台假设
- **变更类型**: 澄清
- **描述**: macOS 26 (Tahoe) 于 **2025年9月15日** 正式发布，当前最新版本为 **26.5.1** (2026年6月1日)。WWDC 2026 将于 2026年6月8日 揭晓 macOS 27。DeepFinder 的 macOS 26 最低要求完全合理，无需紧急回移植。可选评估是否支持 macOS 25 (Sequoia) 以扩大用户群。
- **影响**: 审计中 "macOS 26 unreleased, zero users" 的 CRITICAL 发现作废。兼容性文档方向从紧急回移植改为可选的向下兼容评估。

### CHG-2026-06-03-03: 竞品数据更新至 2026年6月

- **来源**: 网络验证（nadav）
- **影响 REQ**: 无直接 REQ 影响（参考信息更新）
- **影响文档**:
  - `docs/COMPARISON.md` — 更新所有竞品版本和数据
  - `docs/superpowers/specs/ux/` — UX 竞品对标更新
- **变更类型**: 修改
- **描述**: 以下竞品信息经验证更新：

| 竞品 | 最新版本 | 日期 | 关键变化 |
|------|---------|------|---------|
| Everything | 1.5 Beta | 2026-05-14 | 5年Alpha后正式Beta；增强过滤语法，多窗口模式，持久化索引 |
| Alfred | 5.7.3 | 2026-04-01 | **无内置AI**（仅社区工作流DIY），$34一次性，macOS 26兼容 |
| Raycast | 2.0 公测 | 2026-05 | Windows支持，GPT-5 mini，Rust文件索引器，$8/月 |
| Spotlight | macOS 26.5 | 2026-05 | 4种模式+Actions _但可靠性投诉激增_ — 差异化价值增强 |
| HoudahSpot | 6.8.1 | 2026-03-26 | 基于Spotlight引擎，macOS 10.14+，$30一次性 |

- **关键洞察**:
  - **Spotlight 可靠性仍然糟糕** — macOS 26 升级后大量用户抱怨搜索损坏。DeepFinder 独立索引的价值主张**比以往更强**
  - **Alfred 无内置 AI** — 与审计中假设不同。Alfred 定位为「隐私优先的一次性付费工具」
  - **Raycast 2.0 跨平台** — 已推出 Windows 原生支持，AI 深度集成
  - **Everything 1.5 终于 Beta** — 5年Alpha结束，但仍是 Windows 独占

### CHG-2026-06-03-04: 建立需求变更追踪流程

- **来源**: nadav（项目 owner）
- **影响 REQ**: 无（流程变更）
- **影响文档**:
  - `CLAUDE.md` — 新增「需求变更追踪」章节
  - `docs/superpowers/specs/REQ_CHANGE_LOG.md` — 本文件
- **变更类型**: 新增
- **描述**: 建立需求变更强制记录流程。每次需求改动必须：
  1. 在本文件记录变更条目
  2. 更新受影响的 REQ 文件（状态图标等）
  3. 更新 `REQ_STATUS.md` 统计
  4. 更新 CLAUDE.md（如影响工作流）
  5. 更新相关设计文档和 plans
- **影响**: 所有未来需求改动均需遵循此流程。Claude Code 在每次修改需求相关文件前应检查本日志。

---

## 2026-06-14 — REQ 卡片格式重构为 OSS 标准 BDD

### CHG-2026-06-14-01: 需求列表重构为开源标准 BDD 格式

- **来源**: nadav（ultracode 目标——按开源标准重构需求管理方式；MCP 查证：OSS 标准管理 = 用户故事 + Given/When/Then BDD + 可溯源实现/测试）
- **影响 REQ**: 全部 158 项（**格式变更，非内容变更**）
- **影响文档**:
  - 19 个 `reqs/v*.md` 文件——全部卡片重写为 BDD 模板
  - `reqs/00-overview.md`——新增格式说明
  - `reqs/REQ_STATUS.md`——新增格式说明（统计不变）
  - `CLAUDE.md`——「REQ 文件格式」约定更新
- **变更类型**: 修改（格式）
- **描述**: 全部 158 项 REQ 卡片从「`[ ]`/`[x]` 复选框验收标准」重写为 OSS 标准 BDD 格式：
  - **用户故事**：作为「角色」，我希望「能力」，以便「价值」（As a / I want / so that）
  - **验收标准**：Given / When / Then 场景（每个行为点一组）
  - **实现 / 测试**：文件溯源（`Sources/...` · `Tests/...`，取自 REQ_STATUS.md）
  - 废弃易与现实脱节的 `[ ]`/`[x]` 复选框（重构前存在 1100+ 个失效勾选——done 状态的 REQ 绝大多数验收标准仍为未勾选）。
  - 内容语义、状态图标（✅/📋/❌/🔀）、优先级、执行图标、REQ ID 与计数**全部不变**。
  - 金标准参考：`reqs/v0.1-index-core.md`（手工编写）；其余 18 文件按此模板由 subagent 并行重写，经一致性校验（158 卡片 = 158 用户故事，939 条 Given，0 残留复选框，0 断链）。
- **影响**: 所有 REQ 文件统一为 BDD 模板，自描述、可被 BDD 工具解析、验收标准与现实一致。CLAUDE.md「REQ 文件格式」约定同步更新（明确禁用复选框式验收标准）。

### CHG-2026-06-14-02: 修正 REQ_STATUS 中 API Key 存储描述（Keychain → .env）

- **来源**: nadav（REQ BDD 重构中发现既有内容错误）
- **影响 REQ**: REQ-3.0-03 / REQ-3.0-04（仅状态矩阵 Notes 列文字）
- **影响文档**: `reqs/REQ_STATUS.md`（第 273–274 行）
- **变更类型**: 修改（澄清）
- **描述**: REQ_STATUS.md 中 REQ-3.0-03/04 的 Notes 误写「Keychain API key」，与 CHG-2026-06-03-01（确认 API key 存于 `~/.deep-finder/.env`，permissions 600，**不**迁移 Keychain）及 REQ-3.0 卡片原文（`.env` 600）冲突。现统一为「API key in ~/.deep-finder/.env (600)」。REQ 卡片内容无需改动（本就正确）。
- **影响**: 状态矩阵与密钥存储决策（CHG-2026-06-03-01）及卡片描述一致；消除「Keychain vs .env」的内部矛盾。

### CHG-2026-06-14-03: 全量 doc↔impl 一致性核查与调和（每个 AC 对应实现）

- **来源**: nadav（目标「每个需求有架构文档 + 每个架构文档有对应实现」）
- **影响 REQ**: 全部 158 项（行为级核查 v0.1–v3.2 全 19 文件）
- **影响文档**: 全部 19 个 `reqs/v*.md`
- **变更类型**: 修改（规格同步现实）
- **描述**: 对每个 REQ 的 Given/When/Then 验收标准逐一比对代码+测试。对描述了**未实现行为**的 AC，重写为描述**实际实现的行为**（保留 Given/When/Then 结构、中文、AC 意图）。仅 REQ-0.1-06 AC7（`deleteBatch`）与 REQ-0.1-07 AC3（1M 固件）以**新增实现**满足；其余均规格侧调和。最终：**每个 AC 都有对应实现**（doc = impl）。校验：158 REQ、0 复选框、0 断链、0 缺失源/测试引用、build clean。
- **发现的主要过度声明**（现已在卡片中如实反映，供后续实现决策）：
  - v1.1 通配符/正则 AST 节点在搜索流水线被扁平化为子串查询；`PatternMatcher.matchWildcard/matchRegex` 无生产调用方（仅测试）。
  - v1.3 `:bm`/`:filter`/`:sort` REPL 命令、`--bookmark`、宏展开、排序持久化均**未实现**（仅底层 BookmarkStore/SavedFilter IPC/SearchSorter 存在）。
  - v1.4 `content:` 语法**未接入** QueryParser（内容搜索不可经查询语法触达）；扫描串行、cancel 为 no-op。
  - v1.5 `dupe:`/`sizedupe:`/`hashdupe:`/`empty:` **未被 QueryParser 解析**（仅 `len:` 端到端可用）。
  - v3.0 多数 AI 库组件（NL 翻译/摘要/建议/语义分组/图像相似/Vision 标注/剪贴板）已实现+测试，但**未接入 CLI/GUI**；NLOperations 为本地规则匹配（非 AI）。
  - v3.2 type-to-select、sticky/可折叠分类、双向过滤 chip 均未实现。
- **影响**: 规格不再声明未实现的行为；后续若决定实现上述「过度声明」功能，应作为新 REQ（走 5 步变更流程）而非视为既有 AC 的回归。

---

## 2026-06-15 — 实现重复查找端到端接线

### CHG-2026-06-15-01: 重复查找 CLI↔daemon 端到端接线（dupe:/sizedupe:/hashdupe:/empty:）

- **来源**: nadav（doc↔impl 调和暴露的过度声明功能——后端完整但两端未接线）
- **影响 REQ**: REQ-1.5-01 / 02 / 03 / 04 / 06（新增端到端 AC5）
- **影响文档**: `reqs/v1.5-duplicate.md`；代码 `Sources/CLI/DuplicateCommand.swift`、`SingleShot.swift`、`REPL.swift`、`TerminalFormatter.swift`、`DaemonMain.swift`
- **变更类型**: 新增（实现）
- **描述**: 重复查找后端（`DuplicateFinder`）与 IPC 传输（`.duplicateQuery`/`.duplicates`）本已完整，但 daemon 用默认空 `duplicateProvider`、CLI 把所有非命令输入当普通 `.query`——故 `dupe:`/`hashdupe:` 从未到达查找器（doc↔impl 审计将此标为过度声明）。本次接线两端：daemon `makeIPCServer` 提供真实 `duplicateProvider`（`.hash` 两阶段 size 预筛）；CLI `DuplicateCommand.detect` 识别前缀并路由（single-shot + REPL）；`TerminalFormatter.formatDuplicates` 提供 JSON/NUL/分组 ANSI 输出。README 的「Duplicate detection」headline 现名副其实。
- **影响**: REQ-1.5 ACs 更新为反映完整端到端路径（含新 AC5）；v1.5 两处「CLI 未实现」备注修正。测试：DuplicateCommandTests 6 + formatDuplicates 4；CLITests 152 全绿；build clean。

---

### CHG-2026-06-15-02: content: 内容搜索端到端接线（文件级）

- **来源**: nadav（doc↔impl 调和暴露的过度声明功能——后端完整但未触达）
- **影响 REQ**: REQ-1.4-01（AC1 重写）
- **影响文档**: `reqs/v1.4-content-search.md`、`README.md`；代码 `Sources/Daemon/IPCServer.swift`、`DaemonMain.swift`
- **变更类型**: 新增（实现）
- **描述**: `ContentSearchProvider`/`ContentScanner` 已完整实现+测试，但 daemon 仅注册 `FileIndexProvider`、`content:` 未路由（doc↔impl 审计标为过度声明）。内容扫描昂贵，必须 opt-in。本次接线：IPCServer 新增 `contentSearchHandler` 闭包，`.query` 分支检测 `content:` 前缀（廉价门控）→ 剥离前缀 → 调用 handler；daemon handler 每次查询新建 `ContentSearchProvider` 运行扫描、返回 `.results`（`.substring`）。普通查询完全绕过（文件名搜索保持亚毫秒）。**当前为文件级结果**（哪些文件含该词）；行级匹配详情未经 IPC 返回（未来增强）。README 由「line-level matching」更正为「find files whose contents contain a string」。
- **影响**: REQ-1.4-01 AC1 重写为反映实际路由路径；README 内容搜索描述如实。测试：IPCServerTests 新增 content 路由测试（11 全绿）；build clean。

---

### CHG-2026-06-15-03: :bm 书签命令端到端接线（list/save/delete）

- **来源**: nadav（doc↔impl 调和暴露的过度声明功能——底层完整但两端未接线）
- **影响 REQ**: REQ-1.3-01（新增端到端 AC8）
- **影响文档**: `reqs/v1.3-search-exp.md`；代码 `Sources/Daemon/IPCServer.swift`、`DaemonMain.swift`、`Sources/CLI/REPLCommands.swift`、`REPL.swift`
- **变更类型**: 新增（实现）
- **描述**: `BookmarkStore`（Search actor，JSON 持久化）+ IPC `bookmarkList/Save/Delete` case 已存在，但 daemon 把所有 bookmark/filter IPC 桩为 `.ack`（不持久化）、REPL 无 `:bm` 命令（审计标为过度声明）。本次两端接线：daemon `makeIPCServer` 创建 `BookmarkStore`（持久化 `~/.deep-finder/bookmarks.json`）并接 3 个 IPC 闭包；IPCServer 路由 bookmark case（不再 `.ack`，filter 仍 `.ack`）；CLI 新增 `REPLCommand.bookmark`（别名 `:bm`）+ `handleBookmark`（`:bm`/`:bm save NAME`/`:bm delete N`）。
- **影响**: REQ-1.3-01 新增 AC8（端到端 REPL/daemon）；`:bm` 命令名副其实。仍未实现：`:sort`、`:filter` 宏、`--bookmark` flag（备注标注）。测试：IPCServerTests bookmark 路由（12 全绿）、CLITests 156 全绿、build clean。

---

### CHG-2026-06-15-04: :filter 宏命令端到端接线（list/save/delete/apply）

- **来源**: nadav（doc↔impl 调和暴露的过度声明功能——IPC 类型在但两端未接线）
- **影响 REQ**: REQ-1.3-02（新增端到端 AC6）、REQ-1.3-06（IPC 说明修正）
- **影响文档**: `reqs/v1.3-search-exp.md`；代码 `Sources/Daemon/FilterStore.swift`（新）、`IPCServer.swift`、`DaemonMain.swift`、`Sources/CLI/REPLCommands.swift`、`REPL.swift`
- **变更类型**: 新增（实现）
- **描述**: `SavedFilter` 类型 + IPC `filterList/Save/Delete` 已存在，但 daemon 桩为 `.ack`（不持久化）、REPL 无 `:filter` 命令。本次两端接线：新增 `FilterStore` actor（upsert-by-name，持久化 `~/.deep-finder/filters.json`）；IPCServer 路由 filter case（不再 `.ack`）；CLI 新增 `REPLCommand.filter` + `handleFilter`（`:filter`/`:filter save NAME EXPR`/`:filter delete NAME`/`:filter apply NAME`，apply 重跑 `上次查询 + 过滤表达式`）。宏展开经 `:filter apply` 实现而非查询内联 `:name`（避免与 REPL `:` 命令命名空间冲突）。
- **影响**: REQ-1.3-02 新增 AC8（端到端）+ REQ-1.3-06 IPC 说明修正。测试：FilterStoreTests 4 + IPCServerTests filter 路由（13 全绿）+ CLITests `:filter` 解析（160 全绿）；build clean。

---

### CHG-2026-06-16-01: wildcard/regex 接入搜索流水线

- **来源**: nadav（doc↔impl 调和暴露的过度声明功能——PatternMatcher 已实现但无生产调用方）
- **影响 REQ**: REQ-1.1-02（通配符）、REQ-1.1-03（正则）、REQ-1.1-06（AC8）
- **影响文档**: `reqs/v1.1-advanced-syntax.md`；代码 `Sources/Search/FileIndexProvider.swift`
- **变更类型**: 新增（实现）
- **描述**: `PatternMatcher.matchWildcard`/`matchRegex` 已实现+测试，但无生产调用方——wildcard/regex AST 节点经 `textOnlyQuery` 扁平化为子串文本，故 `*.pdf`/`regex:...` 从不按模式匹配（审计标为过度声明）。本次接线：`FileIndexProvider.performSearch` 检测 cleanQuery 中的 glob（`*`/`?`）与 `regex:` 前缀，扫描全部记录并经 `PatternMatcher` 匹配（上限 `maxResults`，结果归类为 `.substring`、score 0.6）。普通查询不受影响（廉价前缀/字符检测，仍走索引子串路径）。
- **影响**: v1.1 三处「PatternMatcher 无生产调用方 / 扁平化为子串」AC 已更正 + 顶部更新说明。README「Wildcards (`*.pdf`)」「regex:」headline 名副其实。测试：SearchProviderTests 新增 5（`*.ext`/`*term*`/`prefix*`/`regex:^report`/plain-unaffected），SearchTests 223 全绿；build clean。

---

## 2026-06-19 — single-shot --bookmark flag 接线

### CHG-2026-06-19-01: --bookmark NAME single-shot flag 端到端接线

- **来源**: nadav（doc↔impl 残留——REQ-1.3-01 备注与 REQ_STATUS 声称 "CLI --bookmark" 但实测缺失）
- **影响 REQ**: REQ-1.3-01（新增 AC9）
- **影响文档**: `reqs/v1.3-search-exp.md`；代码 `Sources/CLI/ArgParser.swift`、`Sources/CLI/CLIMain.swift`
- **变更类型**: 新增（实现）
- **描述**: `BookmarkStore` + IPC `bookmarkList` + REPL `:bm` 已端到端可用，但 single-shot `--bookmark NAME` flag 缺失（审计标为残留过度声明）。本次接线：ArgParser 新增 `--bookmark NAME` 值 flag → `CLIOptions.bookmark`；CLIMain 在子命令派发后、REPL 守卫前新增 bookmark 分支，经 `.bookmarkList` 取回书签按名称解析其 `query`，再走正常 single-shot 路径（复用 `SingleShot.execute`，可与 `--json`/`--limit`/`--sort` 组合）。未知名称 → exit code 3（queryError）。
- **影响**: REQ-1.3-01 新增 AC9；备注从「未实现——未来增强」改为已接入；REQ_STATUS「CLI --bookmark」描述名副其实。测试：ArgParserTests 2（解析 + 缺值报错）+ CLIMainTests 2（解析并运行 / 未知名称报错），CLITests 164 全绿；build clean。

---

## 2026-06-19 — REPL :sort 跨会话持久化

### CHG-2026-06-19-02: :sort 偏好持久化到 daemon 配置（跨会话保留）

- **来源**: nadav（doc↔impl 残留——REQ-1.3-04 用户故事要求"跨会话沿用"，备注标注"DaemonConfig 无 sort 字段"）
- **影响 REQ**: REQ-1.3-04（新增 AC5）
- **影响文档**: `reqs/v1.3-search-exp.md`；代码 `Sources/Search/SearchSorter.swift`、`Sources/Daemon/ConfigStore.swift`、`Sources/CLI/REPL.swift`
- **变更类型**: 新增（实现）
- **描述**: REPL `:sort` 命令已实现但偏好仅存于会话内（进程退出失效）——审计标注的残留过度声明。本次接线：`DaemonConfig` 新增可选字段 `sortPreference: String?` / `sortReverse: Bool?`（前向兼容：旧 `settings.json` 无此字段时 Codable 解码为 nil，不影响其余字段）；`serializedDictionary()` + `ConfigStore.set` 暴露 `sort`/`sortReverse` 键（空串清空，非法值拒绝）；REPL 启动时 `loadSortPreference()` 载入、每次 `:sort` 变更 `persistSortPreference()` 原子写入。`SortCriterion` 新增 `persistenceKey` / `from(persistenceKey:)` 作为单一映射源。Single-shot 仍由 `--sort`/`--reverse` flag 表达（不自动套用已存偏好，符合 AC1-4）。
- **影响**: REQ-1.3-04 新增 AC5；备注从「跨会话持久化为未来增强」改为已实现。测试：ConfigStoreTests 4（往返 / 空串清空 / 非法拒绝 / 前向兼容）+ REPLTests 2（启动载入 / 变更持久化）；ConfigStoreTests 16 全绿、CLITests 166 全绿；build clean。

---

## 2026-06-19 — content: 行级匹配经 IPC 返回

### CHG-2026-06-19-03: content: 行级匹配（line:column）经 IPC 返回并渲染

- **来源**: nadav（doc↔impl 残留——REQ-1.4-03 声称 `line:column` 输出，但行级 `ContentMatch` 暂存于 provider 实例、未经 IPC 返回、TerminalFormatter 未渲染）
- **影响 REQ**: REQ-1.4-01（备注）、REQ-1.4-03（AC3 / AC5 / AC7）
- **影响文档**: `reqs/v1.4-content-search.md`；代码 `Sources/Search/SearchTypes.swift`、`Sources/Search/ContentScanner.swift`、`Sources/Daemon/DaemonMain.swift`、`Sources/CLI/TerminalFormatter.swift`
- **变更类型**: 新增（实现）
- **描述**: `ContentSearchProvider` 已在 `storedMatches` 持有行级 `ContentMatch`，但 daemon contentSearchHandler 丢弃了它们、CLI 只见文件级结果。本次接线：新增 `ContentMatchWire`（Codable：`filePath`/`lineNumber`/`lineContent`/1-based `column`，将非 Codable 的 `matchRange` 转为列号）；`SearchResult` 新增可选 `contentMatches: [ContentMatchWire]?`（默认 nil，前向/后向 Codable 兼容，自定义 `==` 不变）；daemon handler 经 `contentMatches(for:)` 取回并填充；TerminalFormatter 在文件名行下渲染 `    {lineNumber}:{column}  {lineContent}`（每文件 ≤5 行 + `+N more`）。`--json` 经 Codable 自动包含 `contentMatches`；`--0` 仅路径不变。
- **影响**: REQ-1.4-01 备注从「行级展示为未来增强」改为已实现；REQ-1.4-03 AC3/AC5/AC7 重写为反映实际渲染/行数限制/JSON 行为。测试：SearchTypesTests 1（ContentMatchWire 列号换算）+ TerminalFormatterTests 3（渲染 / JSON / 文件名结果无匹配行）；SearchTypesTests 10 全绿、CLITests 169 全绿；build clean。

---

## 2026-06-21 — 索引引擎重构（单分配 entry + 字符串去重 + 二进制持久化）

### CHG-2026-06-20-01: CIndex 单分配 DFileMeta + 二进制 index.bin 替换 SQLite（spec 2026-06-20 落地）

- **来源**: 对标 Cling (macOS) + FSearch (C) 调研；spec `docs/superpowers/specs/2026-06-20-index-engine-refactor-design.md`、plan `2026-06-20-index-engine-refactor-plan.md`
- **影响 REQ**: REQ-v0.1 索引核心（InMemoryIndex / FileRecord / 持久化相关 REQ）
- **影响文档**:
  - `CLAUDE.md` — Project 段（pure Swift → Swift + C 索引库）、Directory Structure（加 `CIndex/`、`Persist/` 改 BinaryIndex/LegacySQLiteReader）、Architecture（Index 结构 Trie/FullSubstringMap/PinyinIndex → CIndex DFileMeta + sorted-names + trigram；Persistence SQLite WAL → `index.bin`）、Daemon lifecycle、Team 表
  - `docs/superpowers/specs/2026-06-20-index-engine-refactor-design.md` — 状态 Draft → Implemented（P0–P4 完成）
  - `docs/superpowers/specs/2026-06-19-metadata-filter-restore-design.md` §7 — 持久化基底 SQLite → 二进制（合流，待 P5 后续落实内联）
- **变更类型**: 修改（架构重构）
- **描述**: 索引后端重构完成（branch `refactor/index-engine`，**未合并 main**）：
  - **B1** path hash 扩容（负载因子 >0.5 翻倍 rehash）+ **B2** id→meta O(1) 直接映射（pre-existing P0）。
  - **path_remove** 改 backward-shift 删除（Knuth Algorithm R），修复开放寻址碰撞链中间删除导致后续 `path_lookup` 漏查的 bug。
  - **P1** 单分配 `DFileMeta`（flexible array member）替换 FileMeta+NameSlot+PathSlot：5 malloc→1 calloc；name/lower_name/path/parent 内联；NameSlot/PathSlot 改非拥有指针指向 entry。
  - **P2** trigram 去重：CTrigramIndex 删除自有 arena 小写副本，存非拥有指针指向 `DFileMeta.lower_name`；filename 3→2 份。
  - **P3** 二进制 `index.bin`（DFIX header + 长度前缀记录 + metadata JSON + cursor sidecar）替换 SQLite；`IndexPersistence`（actor）委托 `BinaryIndex`，公共 API 不变、daemon 7 个调用点零改动；`IndexRecovery` 改二进制感知（坏 header → 删 + 重扫）；path/parent 仍 AES-256-GCM fail-closed。
  - **P4** 一次性 SQLite→binary 迁移（`LegacySQLiteReader`），失败回退重扫。
- **影响**: 内存 ~423B→~250B/记录（5 malloc→1 + 字符串去重）；启动从 SQLite 逐行解码改为二进制 bulk 解析 + 旧库自动迁移。测试：IndexTests 48、PersistTests 71（含 BinaryIndex 12 + SQLiteMigration 5）全绿；DaemonMain/FSEventWatcher 字节不变。**未合并 main**（待 review + 合流决策）；REQ 内联状态图标更新（v0.1-index-core）留作 P5 后续。

---

## 2026-06-22 — 移除全部 SQLite 逻辑

### CHG-2026-06-22-01: 删除 SQLite 依赖（放弃迁移，纯二进制持久化）

- **来源**: nadav（用户决策——索引引擎重构后彻底去除 SQLite）
- **影响 REQ**: REQ-v0.1 持久化相关
- **影响文档**: `CLAUDE.md`（Project / Directory / Persistence 段去除 SQLite / migration 表述）；`REQ_CHANGE_LOG`
- **变更类型**: 废除
- **描述**: P4 的 SQLite→binary 迁移（`LegacySQLiteReader`）连同 `SchemaMigrator`、`SQLTransient`、`import SQLite3`、`SQLiteMigrationTests` 一并删除。`Package.swift` 本无 sqlite3 linker（仅 `linkedLibrary("edit")` for readline），故删掉所有 `import SQLite3` 即彻底去除 SQLite 依赖。后果：旧的 `index.db` 不再迁移，daemon 重扫一次写入 `index.bin`（与缺失/损坏索引相同的安全回退）。
- **影响**: 零 SQLite 依赖（恢复 "zero external dependencies" 初衷）。IndexTests 60 + PersistTests 66（删 5 个迁移测试）全绿。

---

## 变更统计

| 日期 | 变更数 | 类型 |
|------|--------|------|
| 2026-06-03 | 4 | 废除×1 / 澄清×1 / 修改×1 / 新增×1 |
| 2026-06-14 | 3 | 修改（格式）×1 / 修改（澄清）×1 / 修改（规格同步现实）×1 |
| 2026-06-15 | 4 | 新增（实现）×4 |
| 2026-06-16 | 1 | 新增（实现）×1 |
| 2026-06-19 | 3 | 新增（实现）×3 |
| 2026-06-21 | 1 | 修改（架构重构）×1 |
| 2026-06-22 | 1 | 废除×1 |
