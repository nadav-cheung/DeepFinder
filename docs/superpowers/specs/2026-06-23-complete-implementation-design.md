# DeepFind — 完整实现设计(排除 UI)

**Date:** 2026-06-23
**Status:** **Delivered** — Phases A–F all implemented & merged to `main` (2026-06-24, 118 tests green; see [`../../decisions.md`](../../decisions.md) + [`../../architecture.md`](../../architecture.md) §9–10). *(Design approved 2026-06-23: user confirmed scope + ordering; the body below is the executed plan.)*
**Scope:** 把 DeepFind 的**全部非-UI 功能**实现到完成态。GUI 与交互式 TUI 明确排除。

**依据:**
- 已建成架构:[architecture.md](../../architecture.md)
- 终局技术选型:[tech-selection.md](../../tech-selection.md)
- 锁定设计:`2026-06-22-rust-search-index-cli-design.md`、`2026-06-22-v2-content-index-design.md`
- CLI 路线图:`2026-06-23-v2-cli-parity-roadmap.md`

**基线:** main 上已建成——双层 trigram(文件名 pread + 内容 mmap)× 共享候选引擎 × daemon+CLI 进程模型 × smart-case × boolean AST × 文件名正则 × 过滤/`-g`/`-x`/`--color`/`-0`/`--count`。89 测试绿。

---

## 1. 锁定决策(本轮用户拍板)

| 决策 | 选择 | 理由 |
|---|---|---|
| 增量更新 v2.1(df-watch) | **纳入,放最后做**(Phase F) | 用户要"全部功能";作为独立最后里程碑,在完整测试网兜底,降低 FSEvents 增量合并风险 |
| M7 性能硬化 | **先建基准再硬化**(Phase D,测量驱动) | 避免盲目/过早优化;按 criterion 基准结果选做 |
| bfs 表达式语言 + 多 DB | **两个都做** | 完整 CLI 能力面 |
| 执行节奏 | **全自动 + 安全栏** | 每里程碑 commit;歧义记 `docs/decisions.md` 用默认值继续,不阻塞 |

**默认纳入(无需决策,除非用户纠正):** content-regex、`-n`/`-c` 行号/上下文、`--content`/`--filename` 层选择、`-H` 隐藏、`-p`/`-b` 路径模式、`--max-results` 早退、结果排序(默认:路径深度 + match-kind 加权)。

**明确排除:** GUI、交互式 TUI、launchd 自动拉起(非核心,留 polish)、pinyin/jieba(字节 trigram 已 CJK 可用)、SIMD 解码(标量正确优先,作可选优化)。

**目标平台:** macOS(FSEvents via `notify` crate 抽象)。

---

## 2. 范围

**In:** Phase A–F 全部里程碑。
**Out:** 见上"明确排除"。

---

## 3. 里程碑(6 阶段,顺序执行)

### Phase A — 内容引擎补全(P0 正确性)

**A1 content-regex**
- 引擎级**内容正则**:对 mmap 内容字节片做 `regex.is_match`,复用现有"最长字面 atom 驱动候选生成"模式。
- 当前只有文件名正则;内容层在 regex 模式下被跳过——本里程碑补齐。
- smart-case 条件化 `(?i)`。
- **验证:** content 查询与 `grep -E` 等价(对照测试,含大小写/CJK)。

**A2 `-n`/`-c` 行号/上下文**
- 内容命中后做 **post-verify 位置扫描**,输出**行号 + N 行上下文**(zoekt 式)。
- **验证:** 行号/上下文与 `grep -n`/`-C` 一致。

### Phase B — CLI 功能补齐(P1)

**B1 杂项 flag**
- `--content`/`--filename` 层选择 · `-H` 隐藏文件搜索开关 · `-p`/`-b` 全路径/基名模式 · `--max-results N` 早退(封顶 + 停止流式)。
- **验证:** 各 flag 单测 + 端到端;`--max-results` 提前结束流。

**B2 结果排序**
- 默认:路径深度 + match-kind 加权(Both > Content > Filename);`--sort` 覆盖。
- **验证:** 排序稳定、可复现。

### Phase C — 多 DB / 命名根(P1)

**C1 多 DB**
- `deepfind db add/remove/list`,命名根;搜索 `--db <name>`。
- MANIFEST 扩展多根;跨根 base_docid 映射。
- **验证:** 多根建库、按名搜索、去重正确。

### Phase D — 性能基线 + M7 硬化(测量驱动)

**D1 基准**
- criterion suite(真实语料):建库耗时 · 查询延迟(p50/p99) · 峰值 RSS。
- **验证:** 基准可跑、数字落档到 `docs/perf-baseline.md`。

**D2 硬化**
- 按基准结果**选做**:ASCII 直索引数组 / 2-rarest 交集 / bigram / dirTable shard 剪枝 / per-shard 并行 / madvise 中"测量显示值得"的项。
- 每项独立 commit + 前后基准对比。
- **验证:** 每项量化提升 + 测试全绿。

### Phase E — bfs 表达式语言(P2/L)

**E1 bfs 语言**
- 完整 find 表达式:`-name/-path/-size/-newer/-links` + 布尔 + 括号。
- parser + 求值器,**与现有 `-e/-t/-E/-g/-d` flag 并存**作为高级表达式模式(不替换)。
- **验证:** 与 `bfs` 等价谓词对照测试。

### Phase F — 增量更新 v2.1(最后,最高风险)

**F1 df-watch**
- 新 watcher(`notify` 抽象 FSEvents)+ 每文件 posting 增量合并 + **ArcSwap 无锁 shard 热换** + dir-mtime readdir 复用 + MANIFEST 签名。
- 全量重建保留作 `--force` 兜底。
- **验证:**
  - 文件增删改 → 增量更新 → 查询结果与全量重建**等价**(对照测试)。
  - 热换期间在途查询**不 SIGBUS**(rename-aside 旧 shard,drain 后删)。
  - daemon 重建期继续服务旧 shard(无离线窗口)。

---

## 4. 横切规则(每阶段强制)

- **TDD:** 测试先行(Red-Green-Refactor),superpowers `test-driven-development`。无测试不写产品码。
- **每里程碑自动 commit**(conventional commits,如 `feat(content): engine-level content regex`)。
- **三门:** 每里程碑完成前 `cargo fmt --check` + `cargo clippy --workspace --all-targets -D warnings` + `cargo test --workspace` 全绿,才进下一个。
- **歧义不阻塞:** 遇未决设计细节,记入 `docs/decisions.md`(默认选择 + 理由 + 日期),用默认值继续,不停下等人。
- **不动 UI:** 全程无 GUI、无交互式 TUI。

---

## 5. 完成定义(DoD)

1. Phase A–F 全部里程碑实现 + 测试绿。
2. `cargo fmt --check` / `cargo clippy -D warnings` / `cargo test --workspace` 全绿;criterion 基准可跑。
3. 端到端集成测试各覆盖一个:内容正则 + 行号、多根搜索、bfs 表达式、df-watch 增量。
4. 确认无 GUI/TUI;`docs/decisions.md` 汇总本轮所有默认决策。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| F1 增量合并正确性(最难) | 放最后;增量 vs 全量重建等价对照测试;rename-aside 防 SIGBUS |
| D2 硬化过早 | 先建基准,测量驱动选做,不做无依据优化 |
| E1 bfs 与现有 flag 重叠 | 并存为高级模式,不替换;各自独立测试 |
| 长会话上下文压力 | 每里程碑独立 commit + 决策落档,可跨会话续接 |

---

## 7. 执行入口

实现计划(细化到任务级)由 `writing-plans` skill 产出,存放 `docs/superpowers/plans/`。
执行由 goal 命令驱动(全自动 + 安全栏),按 Phase A→F 顺序推进。
