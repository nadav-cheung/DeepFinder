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

## 变更统计

| 日期 | 变更数 | 类型 |
|------|--------|------|
| 2026-06-03 | 4 | 废除×1 / 澄清×1 / 修改×1 / 新增×1 |
