# DeepFind — 开源 1.0 发布设计

**Date:** 2026-06-24
**Status:** Design approved (user confirmed all locked decisions 2026-06-24)
**Scope:** 把 DeepFind(Rust 重写版)发布为开源 1.0 —— 版本号、macOS 标准安装路径与命令行分发、自动后台索引、发布自动化。GUI / 交互式 TUI 仍排除。

**依据:**
- 已建成架构:[architecture.md](../../architecture.md)
- 决策日志:[decisions.md](../../decisions.md)
- install/uninstall launchd 特性(已交付,commit 3d28c23)
- df-watch 反馈环修复(已交付,commit fec4e7b)
- 业界对照:`search-analysis/` 内 reflex / lolcate-rs / trigrep / fsearch / fd / zoekt,以及 Everything / Spotlight / plocate

---

## 1. 锁定决策(本轮用户拍板)

| 决策 | 选择 | 理由 |
|---|---|---|
| 分发渠道 | **Homebrew tap + GitHub Release 二进制(curl\|sh)** | macOS 命令行最标准;公式从同一 Release 产物拉二进制 |
| 发布自动化 | **cargo-dist + GitHub Actions** | 业界标准,tag 触发:构建 universal 二进制 + 公式 + installer + 校验和 |
| CPU 架构 | **universal binary(arm64 + x86_64)** | 一个产物覆盖 Apple Silicon + Intel |
| 首个公开版本 | **1.0.0,Rust 视作新产品** | 功能完备(A–F + 131 测试);废弃 Swift 时代的旧标签 |
| 二进制模型 | **只留 `deepfind` 一个二进制(方案 B)** | `deepfindd` 与 `deepfind daemon` 跑同一份代码,独立 `deepfindd` 冗余;一个包/一个二进制,cargo-dist 天然打包 |
| install 后行为 | **自动后台索引(默认根 `$HOME`)** | 对齐 Spotlight/reflex:范围大/构建慢 → 后台跑 + 状态,边建边服务;不阻塞 |

**明确排除(本轮不做):** crates.io 发布、`.pkg` 图形安装包 + notarization、自更新器(更新走 `brew upgrade`)、GUI/TUI、默认全盘索引(walk+读内容太重)。

---

## 2. 范围

**In:** 二进制合并(B)、自动后台索引、版本/标签、cargo-dist 配置、OSS 就绪文件、发布流程。
**Out:** 见上「明确排除」。

---

## 3. 里程碑(5 阶段,顺序执行)

### Phase 1 — 二进制合并(方案 B)

把 `deepfindd` crate 降为**纯库**,只保留 `deepfind` 一个二进制;daemon 走 `deepfind daemon` 子命令。

- `crates/deepfindd/`:删 `[[bin]]` + `src/main.rs`,只留 `lib.rs`(daemon 逻辑:`serve`/`DbSet`/`watch`/查询合并)。
- `crates/deepfind/src/main.rs` 的 `cmd_daemon`:**接管 tracing 初始化**(原 `deepfindd` main 的活),再调 `deepfindd::serve`。
- `crates/deepfind/src/launchd.rs`:
  - 删除 `resolve_daemon_bin`(不再需要找 sibling)。
  - `render_plist` 的 `ProgramArguments` 改为 `[<deepfind 绝对路径>, "daemon"]`。
  - `install(home, exe, watch, load)` 直接用 `current_exe()`(即 `deepfind`)渲染 plist。
  - 更新单测(改为断言 plist 含 `<deepfind> daemon`,删 sibling 解析测试)。
- **验证:** `deepfind daemon` 仍正常起;`deepfind install`/`uninstall` launchd 仍工作(plist 跑 `deepfind daemon`);`cargo build -p deepfind` 只产一个二进制;三门绿。

### Phase 2 — 自动后台索引(1.0 核心新行为)

对齐 Spotlight/reflex:daemon 启动 → 后台构建缺失/过期索引 → 热换 → `status` 报告新鲜度。

- **`DbSet` 纳入 ArcSwap 热换**:`Arc<ArcSwap<DbSet>>`(与现有 shards 热换同构)。查询入口 `load_full()` 取快照,贯穿单次查询。
- **`deepfind install`(无参)**:若无已注册库 → 在 `dbs.toml` 自动**注册 `$HOME` 为被监听库**(root=Some)→ 装 launchd agent。
- **daemon 启动**:对每个已注册库,若索引缺失/过期 → **spawn 后台任务**跑 `build_content_index` → 完成后**重开 `DbSet::open` 并 ArcSwap store**(原子换入)。构建期间 daemon 继续服务:该库暂不出结果,CLI 落 `--direct` 兜底。
- **状态**:`deepfind status` 报告每库 `indexing` / `fresh` / `stale` / `missing`(由索引文件存在性 + mtime + 一个 building 标记文件派生)。
- df-watch 保持实时新鲜(反馈环已修,Phase 1 不动)。
- **验证(TDD):**
  - 后台构建期间查询**不崩**(落 `--direct` 或空结果);
  - 构建完成后结果**等价于** `deepfind index` 全量重建(对照测试);
  - 热换无 SIGBUS(复用 shards 热换的 inode 保活论证);
  - `deepfind install`(全新环境)→ daemon 自动注册+后台索引 `$HOME` → `status` 由 indexing→fresh。

### Phase 3 — 版本号与标签

- `Cargo.toml` workspace `version`: `"0.1.0"` → `"1.0.0"`。
- **废弃 Swift 时代标签**(本地 + 远端):`v0.0.1-beta`、`v0.1.0`…`v0.7.0`、`v1.0.0`、`v1.1.0`(均指向已删除的 Swift 代码,误导)。删前确认无依赖。
- 新增 `CHANGELOG.md`(Keep a Changelog 格式;`## [1.0.0]` 条目汇总 Rust 重写全部特性)。
- 发布提交打 tag `v1.0.0`。
- **验证:** `deepfind --version` 报 `1.0.0`;`git tag` 干净;CHANGELOG 完整。

### Phase 4 — cargo-dist + OSS 就绪

- **cargo-dist 配置**(`[workspace.metadata.dist]` 或 `dist-workspace.toml`):
  - `installers = ["homebrew", "shell"]`
  - `targets = ["universal-apple-darwin"]`(macOS-only:launchd/FSEvents/Unix socket/pread+mmap)
  - `tap = "nadav-cheung/homebrew-tap"`(独立仓库,dist 推公式)
  - `publish-jobs = ["homebrew"]`
  - `install-path`:shell installer 装到用户可写目录(如 `~/.local/bin`);**Homebrew 才是「macOS 标准路径」`/opt/homebrew/bin`** 的主入口
  - `ci = ["github"]`;`[profile.dist] inherits = "release" lto = "thin"`
  - `dist init` 生成 `.github/workflows/release.yml`
- **homebrew-tap 仓库**(一次性,手动建):`github.com/nadav-cheung/homebrew-tap`;配发布 token(dist 用 GitHub App / PAT,`dist init` 引导)。
- **OSS 文件:**
  - `CONTRIBUTING.md`(构建门禁 / TDD / conventional commits / trunk-based / macOS 测试 gotchas,引自 CLAUDE.md)
  - `CODE_OF_CONDUCT.md`(Contributor Covenant 2.1)
  - `README.md` 安装段重写:`brew install nadav-cheung/tap/deepfind` + curl\|sh + `deepfind install`(→ daemon 自启 + 后台索引 `$HOME`)
  - `LICENSE` ✓ 已有
  - `.github/workflows/ci.yml`:`cargo test --all` → `--workspace`(其余 fmt/clippy 不变)
- **验证:** `dist build --tag v1.0.0-rc1` 本地预演产出 universal 二进制 + 公式 + installer;`dist plan` 无错。

### Phase 5 — 发布

- 提交版本+CHANGELOG → `git tag v1.0.0` → `git push origin v1.0.0`。
- `release.yml` 触发:构建 universal 二进制 → 建 GitHub Release → 推 Homebrew 公式到 tap → 生成 `installer.sh` + 校验和。
- **验证(真机):**
  - `brew install nadav-cheung/tap/deepfind` → `/opt/homebrew/bin/deepfind`;
  - `curl -LsSf …/latest/download/deepfind-installer.sh | sh` → 装好;
  - `deepfind install` → daemon 开机自启(launchd)+ 后台索引 `$HOME` + df-watch 实时;
  - `deepfind status` 由 indexing → fresh;`deepfind search` 命中。

---

## 4. 横切规则(每阶段强制)

- **TDD:** 测试先行(Red-Green-Refactor),无测试不写产品码。
- **每里程碑 commit**(conventional commits,如 `feat(release):`、`refactor(daemon):`)。
- **三门:** 每里程碑完成前 `cargo fmt --check` + `cargo clippy --workspace --all-targets -- -D warnings` + `cargo test --workspace` 全绿。
- **歧义不阻塞:** 记 `docs/decisions.md`(默认选择 + 理由 + 日期),用默认值继续。
- **macOS-only 发布**,不碰 Linux/Windows target。

---

## 5. 完成定义(DoD)

1. Phase 1–5 全部实现 + 测试绿(预计测试数 131 → ~140+)。
2. 三门全绿;`cargo build --release` 产 universal(`lipo -info` 确认 arm64+x86_64)。
3. `v1.0.0` 已 tag;GitHub Release 含 universal 二进制 + installer + 校验和。
4. `brew install` 与 curl\|sh 均可装到标准路径。
5. `deepfind install` → daemon 自启 + 后台索引 `$HOME` + `status` 报告新鲜度 + df-watch 实时。
6. OSS 文件齐备(CONTRIBUTING/CoC/CHANGELOG/README 安装段);旧 Swift 标签已删。

---

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 后台索引 + `ArcSwap<DbSet>` 并发正确性 | TDD:构建期间查询不崩、构建后等价全量、热换无 SIGBUS(复用 shards 热换论证) |
| cargo-dist 配置坑(universal target / tap 推送 token) | 先 `dist build --tag v1.0.0-rc1` 本地预演 + `dist plan` 校验;按 dist 官方文档 |
| 默认 `$HOME` 索引偏重 | 走 `ignore` 默认(跳隐藏/gitignored)+ `--max-file-size` 封顶内容;文档说明可 `db remove home && db add X <dir>` 改范围 |
| 删除旧标签可能被引用 | 删前 `git tag -l` + 检查 release/CI 无引用;均为 Swift 时代,无 Rust 依赖 |
| 二进制合并(B)改动刚提交的 install 特性 | Phase 1 同步改 `launchd.rs` + 其单测,保证 install/uninstall 不回归 |
