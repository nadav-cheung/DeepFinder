# User Journey Documentation — Design Spec

**版本**：2.0（专家评审修订版）
**日期**：2026-06-03
**状态**：✅ 已批准
**依赖**：[UX Requirements](../ux/2026-06-03-user-experience-requirements.md) · [Best Practices Research](../../research/2026-06-03-best-practices-research.md) · [Main Design](2026-05-26-deep-finder-design.md)

---

## 1. 概述

从用户视角完善项目文档。经专家评审（UX 研究员、OSS 社区经理、竞品分析师、文档架构师）后，交付六件产出物 + 一项基础设施任务：

| # | 产出物 | 路径 | 定位 | 优先级 |
|---|--------|------|------|--------|
| 1 | UX 需求补充 | `docs/superpowers/specs/ux/2026-06-03-user-experience-requirements.md` | 开发者参考更新 | P0 |
| 2 | 用户行为甬道 | `docs/superpowers/USER_JOURNEY.md` | 内部产品规划工具 | P0 |
| 3 | 用户指南星座（多页） | `docs/index.md` + `docs/how-to/` + `docs/reference/` + `docs/explanation/` | 任务导向操作指南 | P0 |
| 4 | Getting Started 教程 | `docs/tutorial/first-search.md` | 新用户 60 秒成功体验 | P0 |
| 5 | 竞品对比 | `docs/COMPARISON.md` | 用户转化 + 市场定位 | P0 |
| 6 | 获取帮助 | `docs/SUPPORT.md` | 完成用户→贡献者漏斗 | P0 |
| -- | CI 文档检查 | `.github/workflows/docs.yml` | markdownlint + lychee | P1 |

### 1.1 动机

- 当前 USER_GUIDE.md 按技术模块组织，新用户被语法细节淹没
- 缺少独立的 Getting Started 教程 — 这是专家评审中最一致的关键发现（4/4 评审提出）
- DeepFinder 最强的竞争差异化因素（自建索引不依赖 Spotlight、免费/开源）在用户文档中从未明确陈述
- 缺少竞品对比页面 — 这是市场标准内容格式
- UX 需求文档缺少 2026 年最新竞品数据

### 1.2 方法论

**Diataxis 框架**（diataxis.fr）：将文档按两个轴（实践/理论 × 学习/工作）分为四种互斥类型：

| 类型 | 目的 | 用户问 | DeepFinder 示例 |
|------|------|--------|----------------|
| **Tutorial** | 手把手教学，假设零基础 | "我是新人，带我走一遍" | `tutorial/first-search.md` |
| **How-to Guide** | 解决特定实际问题，假设基本能力 | "怎么按文件类型搜索？" | `how-to/find-files.md` |
| **Reference** | 准确、完整、中立的事实 | "deepfinder 接受哪些 flag？" | `reference/search-syntax.md` |
| **Explanation** | 背景、设计理由、权衡 | "为什么 DeepFinder 用 daemon？" | `explanation/architecture.md` |

**黄金法则**：绝不在一份文档中混合类型。教程不应深入解释（应链接出去）。参考不应包含分步指导。

**NNGroup 用户旅程框架**：用户旅程（Journey）= 高层次、跨渠道、带情感、长期；用户流程（Flow）= 产品内具体交互。USER_JOURNEY.md 作为内部规划工具提供宏观旅程视图。

### 1.3 语言政策

| 文档类别 | 语言 | 说明 |
|---------|------|------|
| 用户文档（`docs/*.md`，除 `superpowers/`） | English | README、USER_GUIDE、INSTALL、API、COMPARISON、SUPPORT、CONTRIBUTING 等 |
| 内部规划文档（`docs/superpowers/`） | 中文或英文，作者自定 | Specs、plans、ADRs、research |
| USER_JOURNEY.md | 中文 | 位于 `docs/superpowers/`，属内部规划文档 |

欢迎社区贡献用户文档的翻译版本。

---

## 2. 交付物 1：UX 需求文档更新

### 2.1 补充项

| # | 补充内容 | 来源 | 影响的章节 |
|---|---------|------|-----------|
| 1 | Alfred 2026.4 onboarding 实践：统一权限面板、勾选反馈 | Alfred Blog 2026.4 | §5.3 UX-O03/O04 验收标准 |
| 2 | FileMinutes folder-scoped 搜索语法作为竞品参考 | fileminutes.com | §2.1 竞品矩阵（新增行） |
| 3 | NNGroup 旅程 vs 流程区分 | NNGroup 2023 | §1.1 方法论补充 |
| 4 | 6款 Mac 文件搜索工具对比数据（含 Fenn） | fileminutes.com + 网络调研 | §2.1 竞品矩阵扩展 |
| 5 | 「零外部依赖」的 OSS 差异化证据 | DocFetcher 用户反馈 | §4 UX-D05 强化 |
| 6 | ProFind AI 图片搜索对标 | fileminutes.com | §2.1 + §8 验证 Vision Tagging |
| 7 | UX-D06：免费/开源声明须出现在所有用户文档前三句 | 专家评审 CF-3 | 新增 §3 |
| 8 | UX-D07：竞品对比页面需求（含可复现 benchmark） | 专家评审 CF-4 | 新增 §3 |

### 2.2 不补充的

- Alfred Workflow 细节（非文件搜索相关）
- Windows Everything OS 级差异（已覆盖）
- 一般 UX 方法论（放入 Diataxis 结构 explanation/ 中）

---

## 3. 交付物 2：USER_JOURNEY.md（内部规划文档）

**位置**：`docs/superpowers/USER_JOURNEY.md`（评审建议：NNGroup 旅程地图是内部产品规划工具，不应放在用户文档区）

### 3.1 文档结构

```
1. 概述 — 一句话定位 + 3个用户画像速览
2. 旅程总览图 — 8阶段漏斗 + 摩擦矩阵（替换 emoji 情绪弧线）
3. 阶段详解（每阶段 150-300 字 + 无障碍说明 + 可访问性注释）
4. 核心循环泳道图（4列：用户动作 / 系统响应 / 时间约束 / 技术上下文）
5. 流失风险矩阵（含 Owner / 成功指标 / 目标版本）
6. 竞品对标摘要（2句 + 链接到 UX Requirements 和 COMPARISON.md）
7. 审查节奏
```

### 3.2 关键设计变更（评审后）

| 变更 | 原设计 | 修订后 | 理由 |
|------|--------|--------|------|
| 位置 | `docs/USER_JOURNEY.md` | `docs/superpowers/USER_JOURNEY.md` | CF-5：NNGroup 旅程地图是内部规划工具 |
| 情绪表达 | 统一 emoji（😊😐😟） | 按画像区分的摩擦描述矩阵 | CF-12：开发者 200 次/天是"流畅"非"愉悦" |
| 泳道图 | 3 列 | 4 列（+技术上下文：daemon/FDA/索引状态/卷挂载） | 评审 H-1：同样的操作在不同系统状态下体验截然不同 |
| 竞品数据 | 完整竞品快照 | 2 句摘要 + 链接到 UX Requirements + COMPARISON.md | CF-7：三文档重复 |
| Core Loop 命名 | "核心循环" | "日常使用"（Search & Act） | 评审 M-3：NNGroup 要求用户视角命名 |
| 搜索失败事件 | 无 | Core Loop 中新增"搜索失败"子事件：焦虑→解决→信任加深 | 评审 H-5：这是 #1 竞争优势时刻 |
| 流失矩阵 | 风险 + 缓解 | + Owner / 成功指标 / 目标版本 | 评审 M-5：NNGroup 要求 Opportunities 列 |
| 重新激活 | 无 | 更新/维护阶段新增"重新激活"子节：升级 macOS 后权限断裂的体验 | 评审 M-2：Alfred 确认这是反复出现的场景 |
| 无障碍 | 无 | 每个阶段新增无障碍注释（至少：首次运行 VoiceOver、Core Loop 键盘、Reduce Motion） | 评审 H-4：UX-M03/M04/M05 已存在但旅程地图未体现 |
| 画像数量 | 1 地图 3 画像 | 同上 + 注明这是对 NNGroup "one map per persona" 规则的刻意偏离 | 评审 M-11：透明化方法论偏离 |
| 成功指标 | 无测量方法 | 新增"测量方法"列，NPS 和留存标注为"愿景 — 测量机制 TBD" | C-3：防止将愿望误标为事实 |

### 3.3 8 个旅程阶段

| 阶段 | 用户目标 | 关键行为 | 成功指标 | 测量方法 |
|------|---------|---------|---------|---------|
| 1. 发现 | 理解 DeepFinder 是什么 | GitHub/HN/Homebrew → README | 3秒内理解价值主张 | 用户测试 |
| 2. 安装 | 60秒内安装完成 | `brew install` / DMG 拖拽 | 安装到首次搜索 ≤60s | 手动计时 |
| 3. 首次运行 | 完成首次搜索 | 权限引导 → 索引 → 输入查询 | Aha Moment <100ms | Instruments 时间剖析 |
| 4. 日常使用 | 找到目标文件 | ⌃⌘K → 输入 → 浏览 → 操作 | 唤起→操作完成 <2s | Instruments 时间剖析 |
| 5. 探索配置 | 按习惯定制 | 排除目录/自定义热键/AI开关 | 配置变更即时生效 | 功能测试 |
| 6. 高级功能 | 发现进阶能力 | NL搜索/内容搜索/语音输入 | 功能可发现性 | 用户测试 |
| 7. 更新维护 | 保持最新版本 | brew upgrade / Sparkle | 静默更新，不打断 | 发布监控 |
| 8. 推荐传播 | 主动推荐给他人 | 口碑/HN/GitHub Star/博客 | NPS > 50 | 愿景 — 测量机制 TBD。代理指标：GitHub Star 增速、Homebrew 安装量 |

### 3.4 摩擦矩阵（替换 emoji 情绪弧线）

按用户画像 × 阶段描述摩擦级别：

| 阶段 | 开发者 | 知识工作者 | 高级 Mac 用户 |
|------|--------|-----------|-------------|
| 发现 | 低摩擦：HN/GitHub 自然发现 | 中摩擦：需朋友推荐或博客评测 | 低摩擦：效率工具社区主动搜索 |
| 日常使用 | 极低摩擦：肌肉记忆，50-200次/天。痛点：复杂布尔语法错误、FDA 缺失导致遗漏 | 低摩擦：10-30次/天。痛点：语法不熟悉、不知 Quick Look 可用 | 低摩擦：30-80次/天。痛点：默认设置不符合习惯 |
| 配置 | 明确排除 node_modules/.git | 默认够用，开箱即用 | 精细定制热键和外观 |

### 3.5 核心循环泳道图（4 列）

```
用户动作           系统响应                    时间约束        技术上下文
──────────────────────────────────────────────────────────────────────
⌃⌘K 唤起          搜索面板弹出 + 聚焦输入框    <100ms         Daemon: live | FDA: ✅ | Index: live
输入查询字符       实时搜索 + 结果渲染          <50ms/字符     Trie + FullSubstringMap 命中
↑↓ 浏览结果        高亮当前行 + 预览更新        即时           LazyVStack + .equatable()
Space 预览         Quick Look 面板              <200ms         QLPreviewPanel shared
Enter 打开          启动默认应用打开文件          即时           NSWorkspace.open()
Esc 关闭           面板消失 + 焦点回原应用       <100ms         NSApp.hide()
━━━━ 搜索失败事件 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
查询无结果          友好提示 + 搜索建议          即时           FDA 状态检查 → 提示权限问题
文件存在但未找到    焦虑 → 验证索引 → 信任加深   用户手动检查   UX-M06 索引健康指示器
```

---

## 4. 交付物 3：USER_GUIDE.md 星座（多页 Diataxis 结构）

### 4.1 重写策略

**原则**：
- **Diataxis 类型分离**：每份文档只属于一种类型，不混合
- **渐进披露**：通过 `docs/index.md` 导航页实现，不作为文档内部结构
- **意图驱动**：每份 how-to 以用户目标开头
- **保留所有内容**：不删除任何现有信息，重新组织到对应类型的文档中
- **直接入口优化**：70-80% 的文档访问是搜索/书签直接进入，非顺序阅读

### 4.2 新结构

```
docs/
├─ index.md                   ← 着陆页：3 路径入口
│
├─ tutorial/                  ← Diataxis: Tutorial
│  └─ first-search.md         ← 60秒完成首次搜索（新 Deliverable #4）
│
├─ how-to/                    ← Diataxis: How-to Guide
│  ├─ find-files.md           ← 关键词、通配符、扩展名
│  ├─ preview-open.md         ← Enter/⌘Enter/Space/Drag/右键菜单
│  ├─ search-panel.md         ← ⌃⌘K 唤起、输入即搜、GUI 交互
│  ├─ exact-search.md         ← 布尔运算、正则、路径限定、大小写
│  ├─ filter-results.md       ← 大小、日期、类型、媒体元数据
│  ├─ repl-interact.md        ← :open/:explain/:undo/历史
│  ├─ configure.md            ← 排除目录、热键、结果数量
│  ├─ ai-search.md            ← NL 翻译、语音输入、视觉标签、隐私
│  ├─ scripting.md            ← --json、--0、HTTP API
│  ├─ daemon-manage.md        ← 启动/停止/重建/LaunchAgent
│  ├─ faq.md                  ← 10 个最常见问题
│  └─ troubleshooting.md      ← 按症状组织（非子系统）
│
├─ reference/                 ← Diataxis: Reference
│  ├─ search-syntax.md        ← 搜索语法速查表（一页完整表格）
│  ├─ config-keys.md          ← 配置键完整列表
│  └─ file-paths.md           ← 文件路径参考
│
├─ explanation/               ← Diataxis: Explanation
│  ├─ architecture.md         ← Daemon + IPC + 数据流
│  ├─ index-design.md         ← Trie/FullSubstringMap/TrigramIndex 设计理由
│  └─ privacy-model.md        ← 隐私边界、本地 vs. 云端
│
├─ COMPARISON.md              ← 竞品对比（新 Deliverable #5）
└─ SUPPORT.md                 ← 获取帮助（新 Deliverable #6）
```

### 4.3 index.md 着陆页设计

```
┌─────────────────────────────────────────────────┐
│  🚀 DeepFinder User Guide                       │
│                                                  │
│  Find any file on your Mac, instantly.          │
│  Own index. Zero dependencies. Free & open      │
│  source. Replaces Spotlight + Alfred +          │
│  HoudahSpot + EasyFind.                         │
│                                                  │
│  ┌─ I'm new ─────────────────────────────────┐  │
│  │  Take the 60-second tutorial →            │  │
│  └───────────────────────────────────────────┘  │
│  ┌─ I want to... ────────────────────────────┐  │
│  │  Find files  Preview & open  Search       │  │
│  │  with filters  Use AI  Automate with      │  │
│  │  scripts  Configure  Manage daemon        │  │
│  │  [beginner] [intermediate] [advanced]     │  │
│  └───────────────────────────────────────────┘  │
│  ┌─ I need a fact ───────────────────────────┐  │
│  │  Search syntax  Config keys  File paths   │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### 4.4 FAQ 覆盖的问题

1. DeepFinder 和 Spotlight 有什么区别？（含 4 个 Spotlight 具体失败模式）
2. 为什么搜不到某些文件？（FDA 权限 + 排除路径）
3. 全局热键不生效怎么办？
4. 如何排除 node_modules / .git 目录？
5. AI 功能需要联网吗？哪些是本地的？
6. 如何把结果用于脚本？
7. Daemon 连不上怎么办？
8. 如何迁移到新 Mac？
9. 索引占用多少内存？
10. 如何卸载？

### 4.5 故障排查结构

按**症状**组织（非子系统），6 个症状类别：

| 症状 | 3 个最可能原因 | 每原因 1 个修复 | 兜底 |
|------|---------------|----------------|------|
| 搜不到文件 | FDA 未授权 / 路径被排除 / 索引过期 | 引导→设置 / 检查配置 / 重建索引 | `deepfinder diagnose` + 提交 Issue |
| Daemon 启动失败 | 残留 socket / launchd 冲突 / 端口占用 | 清理 socket / 检查 plist / kill 旧进程 | 同上 |
| 搜索慢 | 索引重建中 / 外置卷挂载 / AI 超时 | 等待完成 / 检查卷状态 / 检查网络 | 同上 |
| 热键无效 | Accessibility 未授权 / 冲突 / CGEventTap 失败 | 授 accessibility / 换热键 / 重启 | 同上 |
| AI 不工作 | API Key 未配置 / 网络不通 / 配额耗尽 | 设 key / 检查网络 / 检查配额 | 同上 |
| 安装问题 | Homebrew 404 / 签名验证失败 / macOS 版本 | 更新 brew / 检查公证 / 检查版本 | 同上 |

### 4.6 关键新增内容

| 新增内容 | 位置 | 目的 |
|---------|------|------|
| "Why DeepFinder?" 介绍 | index.md 顶部 | 陈述架构独立性 + 免费/开源 + 替代工具表 |
| Getting Started 教程链接 | index.md 首位 | 新人即时有成功体验（评审 CF-1） |
| FAQ（10 问 + Spotlight 具体失败模式） | how-to/faq.md | 减少 Issue 重复提问 |
| 故障排查（按症状，6 类） | how-to/troubleshooting.md | 用户带着症状来 |
| 搜索语法速查表 | reference/search-syntax.md | 一张表替代散落语法说明 |
| 竞品对比 | COMPARISON.md | 市场标准内容格式（评审 CF-4） |
| 获取帮助 | SUPPORT.md | 完成用户→贡献者漏斗（评审 CF-11） |
| "Get Help / Contribute" 链接 | how-to/faq.md + troubleshooting.md 末尾 | 评审 CF-10 |
| 内容搜索覆盖表 | COMPARISON.md 或 reference/ | 评审 M-9：未列出的能力在竞品评估中不存在 |
| GUI 截图（2-3 张） | how-to/search-panel.md | 评审 M-6：GUI 工具截图是非可选的 |

### 4.7 逐步导航（每篇 how-to 末尾）

每篇 how-to 的末尾包含：
- **🎯 Just learned X?** → 链接到 1-2 个相关的下一步
- **🔍 Need a specific fact?** → 链接到 reference/
- **🤔 Want to understand why?** → 链接到 explanation/

---

## 5. 交付物 4：Getting Started 教程

**路径**：`docs/tutorial/first-search.md`
**类型**：Diataxis Tutorial

### 5.1 内容

单一线性的 60 秒路径，带领新用户从零到成功打开文件。每步一条指令 + 一个预期输出。无语法、配置或架构的题外话。

```
Step 1: brew install nadav/deepfinder/deepfinder    (10s)
Step 2: 打开系统设置 → 隐私 → 完全磁盘访问，勾选 DeepFinder  (30s)
Step 3: deepfinder "myfile"                         (5s)
Step 4: ↑↓ 选择 → Enter 打开                         (15s)
```

完成后链接到：how-to/find-files.md（"想知道更多搜索技巧？"）、how-to/search-panel.md（"试试 GUI？"）

---

## 6. 交付物 5：竞品对比

**路径**：`docs/COMPARISON.md`

### 6.1 内容

对比 DeepFinder 与 Spotlight、Alfred、Raycast、HoudahSpot、EasyFind、Find Any File、Fenn、ProFind：

| 维度 | DeepFinder | Spotlight | Alfred | Raycast | HoudahSpot | EasyFind | Find Any File | Fenn | ProFind |
|------|-----------|-----------|--------|---------|------------|----------|---------------|------|---------|
| 架构 | 自建索引 | Spotlight 索引 | Spotlight 索引 | Spotlight 索引 | Spotlight 索引 | 文件系统暴力 | 文件系统暴力 | 自建索引 | 自建索引 |
| 查询速度 | <1ms | 50-100ms | ~100ms | ~200ms | ~100ms | 秒级 | 秒级 | ~100ms | ~100ms |
| 内容搜索 | ✅ 多类型 | ❌ 不可靠 | ❌ 无 | ❌ 无 | ✅ 深度 | ❌ 有限 | ❌ 无 | ✅ AI 深度 | ✅ 基础 |
| 媒体元数据 | ✅ 全模态 | ❌ | ❌ | ❌ | ✅ EXIF | ❌ | ❌ | ✅ 视频/音频 | ✅ AI 图片 |
| AI 功能 | ✅ 多模型 | ✅ Apple Intelligence | ❌ | ✅ Pro | ❌ | ❌ | ❌ | ✅ 语义搜索 | ✅ 图片搜索 |
| 隐私 | 本地优先 | 系统级 | 本地 | Pro 需云 | 本地 | 本地 | 本地 | 订阅需云 | 本地 |
| 价格 | 免费/开源 | 免费（系统内置） | 免费 + £34 Powerpack | 免费 + $96/yr Pro | ~$34 一次性 | 免费 | ~$6 一次性 | $9-29/mo | 付费一次性 |
| CLI | ✅ 完整 REPL | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 键盘优先 | ✅ | 部分 | ✅ | ✅ | ❌ | ❌ | ❌ | 部分 | ❌ |

含可复现的 benchmark 方法和数据。

---

## 7. 交付物 6：SUPPORT.md

**路径**：`docs/SUPPORT.md`

### 7.1 内容

- 在哪里报告 Bug？（GitHub Issues）
- 在哪里提问？（GitHub Discussions / Issue）
- 有社区论坛吗？（待建）
- 如何请求新功能？（GitHub Issues, Feature Request 模板）
- 安全漏洞如何报告？（SECURITY.md）
- 当 FAQ 和故障排查都帮不上忙怎么办？（`deepfinder diagnose` + 提交 Issue 模板）

---

## 8. 文档所有权与维护

### 8.1 所有权

| 文档 | Owner | 审查节奏 |
|------|-------|---------|
| USER_GUIDE.md 星座 (docs/) | `cli-dev`（主接口是 CLI） | 每个 milestone 版本 |
| USER_JOURNEY.md | `architect`（设计工具） | 每个 milestone + 前 100 Star/50 brew install 后重检 |
| UX Requirements | `architect` | 已在 CLAUDE.md 中建立 |
| COMPARISON.md | `researcher`（竞品数据） | 每季度 + 竞品大版本发布时 |
| SUPPORT.md | `architect` | 每季度 |
| FAQ | `cli-dev` | 每季度审计 GitHub Issues 新常见问题 |

### 8.2 CI 强制

- **markdownlint**：所有 `docs/*.md` 在 CI 中检查
- **lychee**：链接检查器，断链阻止合并
- 已加入 CLAUDE.md docs 维护规则

---

## 9. 与现有文档的关系

```
docs/superpowers/USER_JOURNEY.md (新增)      docs/superpowers/specs/ux/ (更新)
    "内部规划：旅程地图"                            "69→75 项需求"
         │                                              │
         │  引用 ───────────────────────────────────────┤
         │                                              │
         v                                              v
    docs/ (重写为星座)                          技术 REQ 文件 (不变)
    "用户操作指南"                                "158 项技术需求"
         │
         ├── tutorial/first-search.md      ← 新
         ├── how-to/*.md                   ← 重写自 USER_GUIDE.md
         ├── reference/*.md                ← 提取自 USER_GUIDE.md
         ├── explanation/*.md              ← 提取自 CLAUDE.md + ADRs
         ├── COMPARISON.md                 ← 新
         └── SUPPORT.md                    ← 新
              │
              ├── 引用 ──→ API.md
              ├── 引用 ──→ INSTALL.md
              ├── 引用 ──→ INTEGRATIONS.md
              ├── 引用 ──→ CONTRIBUTING.md
              └── 引用 ──→ SECURITY.md
```

---

## 10. 实施顺序

```
Phase 1: 基础设施 + 数据基础
  1. 创建 docs/ 星座目录结构
  2. 更新 UX 需求文档（8 项补充）
  3. 创建 COMPARISON.md（从 UX Requirements 提取竞品数据）
  4. 创建 SUPPORT.md

Phase 2: 核心内容
  5. 创建 tutorial/first-search.md
  6. 创建 explanation/（architecture / index-design / privacy-model）
  7. 创建 reference/（search-syntax / config-keys / file-paths）

Phase 3: 操作指南
  8. 创建 how-to/*.md（从现有 USER_GUIDE.md 提取 + 重组）
  9. 创建 how-to/faq.md + how-to/troubleshooting.md
  10. 创建 docs/index.md 着陆页

Phase 4: 内部规划
  11. 创建 docs/superpowers/USER_JOURNEY.md

Phase 5: 收尾
  12. 删除旧 docs/USER_GUIDE.md（内容已迁移）
  13. 设置 CI: markdownlint + lychee
  14. 更新 CLAUDE.md docs 维护规则

提交策略：每 Phase 内小批量提交，每 commit 一个逻辑变更
```

---

## 11. 一致性检查

- ✅ 竞品数据以 UX Requirements 为权威源，COMPARISON.md 为用户面衍生，USER_JOURNEY.md 只放链接
- ✅ 每份文档属于单一 Diataxis 类型，不混合
- ✅ USER_GUIDE.md 星座内容与 API.md/INSTALL.md/INTEGRATIONS.md 不重复
- ✅ 语言政策明确：用户文档 English，内部规划文档中文
- ✅ 所有引用路径有效（docs/ 内部相对路径）
- ✅ 不修改任何技术 REQ 文件
- ✅ 文档所有权和审查节奏已定义
