# DeepFinder — TCC / Full Disk Access 检测 + 引导设计

> **状态**:📝 设计稿,待实现(2026-06-25)。
> **日期**:2026-06-25
> **依据**:`docs/architecture.md` §9/§10(CLI 能力面 + 已知缺口)、现有 `df-index::is_permission_denied` 反应式告警;`docs/superpowers/specs/2026-06-22-rust-search-index-cli-design.md` §2.3(FDA 运维前提)。
> **范围**:补齐 spec 早期写了但未落地的「daemon 启动时检测 FDA 缺失并引导」。MVP = **检测 + 引导**;不含抗重签/打包改动。

---

## 0. 背景:为什么需要、以及和 cua-driver 的关键分歧

DeepFinder 要读全盘(含 `~/Library/Mail`、`Messages`、`Safari`、`Calendars` 等 TCC 保护目录)建索引 / 直扫,进程必须持有 **Full Disk Access(FDA)**。当前只有**反应式**告警:`df-index` 统计 `permission-denied` 条目,`deepfind index` 结束时打印一行 warning。缺**主动检测**和**引导用户授权**。

**和 cua-driver 模型的根本分歧**(必须先讲清,否则设计会跑偏):

| | cua-driver(Accessibility + Screen Recording) | DeepFinder(Full Disk Access) |
|---|---|---|
| 能否代码触发授权弹窗? | **能**(`AXIsProcessTrustedWithOptions` / 首次截屏触发 consent 对话框) | **不能**——macOS 无任何 API 弹 FDA 授权框 |
| `permissions grant` 的本质 | LaunchServices 起 .app → 触发弹窗 → 等用户在对话框同意 | **无等价物**。用户必须手动到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」加二进制 / 打开开关 |

**因此**:DeepFinder 的「检测到就自动打开」= 自动 `open` FDA 系统设置面板,**不是** consent 弹窗;用户仍要**手动**加 `deepfind` 二进制。本设计不做 `permissions grant`(对 FDA 物理不可能)。

**DeepFinder 比 cua-driver 更简单的一点**:cua-driver 要「通过 daemon 读授权状态、daemon 没跑就 unknown」,因为它的授权挂在 `CuaDriver.app` 上,与终端里跑的 CLI 是两个身份。DeepFinder 的 **daemon(`deepfind daemon`)和 CLI 是同一个 `deepfind` 二进制**(见 `crates/deepfind/Cargo.toml`,唯一 `[[bin]]`;`deepfindd` 是被链入的 lib)→ **CLI 本地 probe 的结果就等于 daemon 的 FDA 状态**,无需走 socket 问 daemon、无需「daemon 没跑就 unknown」那套。

可借鉴 cua-driver:Granted / Denied / ❓ Unknown 三态语义 + 清晰 ✅/❌/❓ 输出。

---

## 1. 锁定的决策

| # | 决策 | 选择 |
|---|------|------|
| 1 | 范围 | **检测 + 引导(MVP)**;不做抗重签稳定性 / .app 打包改动 |
| 2 | 出口面 | **daemon 启动 + `deepfind status` + 新增 `deepfind doctor`** 三处 |
| 3 | 「打开面板」行为 | doctor 检测到缺失(TTY)**自动 open** FDA 面板;非 TTY 只打印;status / daemon 启动**只报告不弹窗** |
| 4 | 检测机制 | **方案 A 主动 probe**(`df-index::fda_state()`),不依赖跑完全量索引 |
| 5 | 放置 | **`df-index`**(新增 `permissions.rs`);**不碰 `df-core`**(守零 I/O 硬约束) |
| 6 | 授权后重启 | **只打印 `launchctl kickstart` 命令**,不替用户执行 |
| 7 | 状态缓存 | **无**(probe 一次 readdir 极便宜,每次现算) |

---

## 2. 范围

### 2.1 本轮交付(in-scope)
- `df-index`:`FdaState` 枚举 + `fda_state()` 探针(readdir 候选受保护目录,errno 分类)。
- `deepfind status`:输出加一行 FDA 状态(报告,不弹窗)。
- `deepfind doctor`(新子命令):跑 FDA 探针 + 自检输出;缺失时自动 open 面板(TTY)/ 打印指引;给出重启命令。
- `deepfindd` 启动路径:probe 一次,`Denied` 时 `tracing::warn!`(不弹窗)。
- 纯函数渲染层(`format_fda_line` 等)便于单测。

### 2.2 明确不做(out-of-scope)
- ❌ `permissions grant`(FDA 物理不可程序化授予)。
- ❌ 读系统 `TCC.db` 判定(用户态进程不可行:SIP / 循环依赖)。
- ❌ 逐类别检测(Mail / Messages / Photos 各自探针)——单一 FDA probe 足矣。
- ❌ 抗重签失效 / `.app` bundle 打包(scope #2 已婉拒)——但**会打印 `current_exe()` 路径**减轻「不知加哪个二进制」的混淆。
- ❌ 授权后自动重启 daemon(只打印命令)。
- ❌ 持久化权限状态缓存。

---

## 3. 放置与组件(守 df-core 零 I/O)

新增 `crates/df-index/src/permissions.rs`,沿用 lib.rs 现有 `is_permission_denied` 的 errno 分类风格:

```rust
/// 当前进程对 Full Disk Access 的启发式判定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FdaState { Granted, Denied, Unknown }

/// readdir 一次候选受保护目录,按 errno 判定 FDA。无副作用。
/// macOS 专属行为;非 macOS 返回 `Unknown`。
pub fn fda_state() -> FdaState { ... }
```

依赖关系不变:`df-index` 已是「可做 fs I/O」的层;`df-core` 保持纯净。

---

## 4. 检测机制(方案 A)

取候选受保护目录里**第一个存在**的,对其 `fs::read_dir`:

| 结果 | 判定 |
|------|------|
| `Ok(_)` | `Granted` |
| `Err(PermissionDenied)` | `Denied` |
| 其他 `Err`(NotFound 等) | 试下一个候选;全部不可用 → `Unknown` |

候选(首选项在实现期实测确认;`read_dir` 打开目录句柄本身即被 TCC 门控):

1. `~/Library/Calendars`
2. `~/Library/Mail`
3. `~/Library/Messages`
4. `~/Library/Safari`
5. `~/Library/Metadata/CoreData`

> **注意**:这是启发式探针(社区标准做法),非 TCC API 查询;但对 `deepfind` 二进制权威。macOS 版本差异可能导致某候选可被无 FDA readdir——故用**列表 + 取首个存在者**,实现期在真机上逐个验证后定首选项,并在测试 gotcha 记录。

---

## 5. CLI 三个出口

### 5.1 `deepfind status`(只报告)
输出增加一行:
```
Full Disk Access: granted      # 或 missing / unknown
```
不弹窗、不 open。

### 5.2 `deepfind doctor`(新子命令,人用自检)
本期主跑 FDA(后续可扩 daemon 健康等,非本期):

- `Granted` → `✅ Full Disk Access: granted`。
- `Denied` →
  - `❌ Full Disk Access: missing` + 指引步骤;
  - 打印**确切二进制路径**(`std::env::current_exe()`,失败回退 `which deepfind` 提示);
  - **TTY 时自动 `open`** FDA 面板:`open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"`(呼应决策 #3「检测到就打开」);
  - 打印授权后**重启命令**(见 §6)。
- `Unknown` → `❓ Full Disk Access: unknown` + 软提示(「若搜索漏掉受保护目录文件,请授予 FDA」)。
- **非 TTY**(管道 / CI):跳过自动 open,仍打印完整指引(避免脚本里弹 GUI)。

TTY 判定:`std::io::IsTerminal`(标准库,Rust 1.70+)。

### 5.3 daemon 启动(只日志)
`deepfindd` 启动时 `fda_state()` 一次;`Denied` →
```rust
tracing::warn!("Full Disk Access not granted; protected dirs (~/Library/Mail, …) will be skipped. Run `deepfind doctor`.");
```
**不弹窗**(daemon 不应起 GUI)。

---

## 6. 授权后要重启(打印命令,不执行)

FDA 授权对**新启动**的进程生效,在跑的 daemon 不会自动获得。LaunchAgent 有 `KeepAlive=true`(`crates/deepfind/src/launchd.rs`),故指引告诉用户重启即生效:

```
After granting, restart the daemon:
    launchctl kickstart -k gui/$(id -u)/cn.com.nadav.deepfind
```

(自动替用户重启留作未来;本期只打印。)

---

## 7. 错误与边界

- `current_exe()` 失败(罕见)→ 回退打印 `deepfind` + `which deepfind` 提示。
- `open` 失败(无 GUI 会话等)→ 忽略错误;指引已打印。
- macOS-only 部分(`open`、候选路径、`launchctl`)`#[cfg(target_os = "macos")]` 门控;非 mac 走 `Unknown` / no-op。
- `fda_state()` 在 daemon 与 CLI **同一二进制**下结果一致(见 §0);无需走 socket。
- 候选目录均不存在(极端洁净系统)→ `Unknown`,不误报 `Denied`。

---

## 8. 测试(守 df-core 纯净 + CI 无 TCC)

- **分类器纯单测**:各种 `io::ErrorKind` → `FdaState`(无需真 TCC)。
- **候选选择单测**:`tempfile::tempdir` 验「全部 NotFound → Unknown」「跳过 NotFound 取首个存在」路径(造不出真 EPERM,该分支留手动验证)。
- **渲染纯函数单测**:`format_fda_line(FdaState)`、TTY/非 TTY 下「是否 open」决策抽成纯函数单独测;`fda_state()` 是唯一 I/O seam。
- **真 FDA 判定**:`#[ignore]` 测试或手跑 `deepfind doctor`(CI 沙箱无 TCC;同现有 TCC 测试 gotcha)。
- **构建门**:`cargo fmt --check` · `cargo clippy --workspace --all-targets -D warnings` · `cargo test --workspace`(项目硬约束)。

---

## 9. 实现顺序建议(供后续 plan 参考)

1. `df-index/src/permissions.rs`:`FdaState` + `fda_state()` + 分类器/选择单测 → verify:单测绿。
2. 纯渲染函数 `format_fda_line` + TTY 决策 + 单测 → verify:单测绿。
3. `deepfind status` 接入一行 → verify:`deepfind status` 输出含 FDA 行。
4. `deepfind doctor` 子命令(探针 + 指引 + TTY 自动 open + 重启命令)→ verify:真机 `deepfind doctor` 行为符合 §5.2。
5. `deepfindd` 启动 probe + warn → verify:无 FDA 启动日志含引导。
6. 全套门禁(fmt/clippy/test)→ verify:全绿。

---

## 附录:状态映射速查

| `FdaState` | status 行 | doctor | daemon 启动 |
|---|---|---|---|
| `Granted` | `granted` | ✅ | 无 |
| `Denied` | `missing` | ❌ + 指引 + (TTY)open 面板 + 重启命令 | `warn!` |
| `Unknown` | `unknown` | ❓ + 软提示 | 无 |
