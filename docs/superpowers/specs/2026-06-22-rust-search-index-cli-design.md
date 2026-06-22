# DeepFinder — Rust 搜索/索引/CLI 重构设计

> **状态**:设计稿,待 review → 转 writing-plans 出实现计划
> **日期**:2026-06-22
> **依据**:`search-analysis/REVIEW.md` §7(竞品评审 + 架构建议)
> **范围**:把搜索 + 索引 + CLI 模块整体重写为 Rust;旧 Swift 工程**完全卸载清理**(clean slate)

---

## 1. 锁定的决策

| # | 决策 | 选择 |
|---|------|------|
| 1 | 实现语言 | **Rust**(edition 2021,resolver 2,最新 stable) |
| 2 | 重构方式 | **整体重写**(非在 Swift+C 内套用),按 REVIEW §7 |
| 3 | 本轮范围 | **v1 文件名索引**(内容索引 = 未来 v2,不含 FSEvents 增量 `df-watch`) |
| 4 | 文件名层方案 | **plocate 式**:文件级 trigram + 单文件 DB + **pread 低 RSS** + zstd 文件名块 + Robin Hood 哈希 |
| 5 | posting 压缩 | **本轮自写 TurboPFor**(PFor delta,block=128,4 流交织解码,`std::simd`/`wide`) |
| 6 | 构建顺序 | **Approach A**:先纵向切片跑通(varint)→ 再硬化(TurboPFor/Robin Hood/zstd/boolean) |
| 7 | 进程模型 | **常驻 daemon + 薄 CLI**,Unix socket,CLI 带 `--direct` 兜底直扫 |
| 8 | 清理策略 | **彻底 clean slate**:全删旧 Swift 源码 + 运行时卸载(含用户数据) |
| 9 | 存储 | **复用 `~/.deep-finder/`**(旧 Swift 本就用;产品继任、引擎换新) |
| 10 | 二进制名 | **`deepfind` / `deepfindd`**(REVIEW §7 命名;`df` 撞 Unix 磁盘命令,不用) |

---

## 2. 范围

### 2.1 本轮交付(in-scope)
- `df-core`:trigram 索引 + 查询引擎 + DB 格式(**纯库,无 I/O 副作用**)
- `df-index`:`ignore` 并行遍历 + TurboPFor 编码 + 原子写单文件 DB
- `df-ipc`:Unix socket 协议(长度帧 + 流式 batch)
- `deepfindd`:常驻 daemon(持 pread DB 句柄、查询线程池、socket server)
- `deepfind`:薄 CLI(IPC 客户端 + `--direct` 兜底)
- 全套 boolean 查询(AND/OR/NOT + 括号,Zoekt 式 —— 从 Swift `ParsedQuery` 移植)
- Clean-slate 卸载:删旧 Swift 工程 + 卸载旧运行时

### 2.2 明确不做(out-of-scope)
- ❌ 内容索引(v2:Zoekt 位置 trigram + mmap shard)
- ❌ FSEvents watcher / 真增量(`df-watch`)
- ❌ GUI(本轮无 GUI;产品 = daemon + CLI)
- ❌ 拼音/jieba(字节 trigram 已 CJK 原生;拼音 = 未来)
- ❌ daemon 自动拉起(launchd 自动启动留作 polish;v1 用 `--direct` 兜底)
- ❌ 多卷自动分片(格式支持多文件;v1 只建启动卷一个 DB)

### 2.3 运维前提
- 全盘索引(`/`)需要 **Full Disk Access**:用户在 System Settings → Privacy & Security 手动授予 daemon;**无法程序化授予**。daemon 启动时检测缺失并引导。(`.env`/`settings.json`/`history` 等用户数据已随 clean slate 删除;FDA 是访问受 TCC 保护目录的前提,与数据目录无关。)

---

## 3. 仓库结构(clean slate 后)

仓库根 = Cargo workspace(像 fd/bfs/reflex)。**无 Swift、无 SPM、无 GUI。**

```
deep-finder/                       # 仓库根
├── Cargo.toml                     # [workspace]
├── Cargo.lock
├── crates/
│   ├── df-core/                   # 纯库:DB 格式 + TurboPFor codec + 查询算法
│   ├── df-index/                  # 索引器:ignore 遍历 → 建 DB → 原子写
│   ├── df-ipc/                    # socket 协议:长度帧 req/resp/stream
│   ├── deepfindd/                 # daemon 二进制
│   └── deepfind/                  # CLI 二进制
├── docs/                          # (本设计文档所在)
├── search-analysis/               # 保留:竞品源码 + REVIEW.md(研究参考)
├── scripts/                       # 仅保留与 Rust 无关的;Swift 专用脚本删除
├── README.md / SECURITY.md / SUPPORT.md / LICENSE / VERSION
├── .gitignore (+target/) / .gitattributes / .editorconfig
├── .github/                       # CI 换成 Rust(fmt/clippy/test)
└── .claude/  .vscode/             # 工具配置保留
```

### 3.1 模块依赖(单向,无环)

```
deepfind  ──▶ df-ipc ──▶ df-core ◀── df-index
   │ (deepfind 还依赖 df-core 取类型 + ignore 做 --direct)
deepfindd ──▶ df-core + df-index + df-ipc
```

### 3.2 `df-core` 纯库规则(REVIEW §5 反 lattice/trigrep 教训)
`df-core` 不碰文件系统、不碰网络。所有查询/codec 逻辑对一个 caller 实现的小 trait 操作:

```rust
trait DbSource {                       // daemon 里用 &File + pread 实现;测试里用 &[u8] 实现
    fn read_at(&self, off: u64, len: usize) -> io::Result<Vec<u8>>;
}
```

这样引擎可脱离真实 DB 单测 + criterion bench(REVIEW §7.0 明确要求)。

### 3.3 关键外部 crate
`ignore`(遍历)、`zstd`(文件名块 + 训练字典)、`tokio` + `tokio-util::codec::LengthDelimitedCodec`(IPC)、`serde` + `bincode`(帧)、`clap`(CLI)、`bytemuck`/`zerocopy`(DB 结构体 cast)、`thiserror`(错误)、`tracing`(日志)、`criterion`(bench,dev)。

---

## 4. 磁盘 DB 格式(plocate 式,单文件)

每卷一个文件,原子写(tmp → fsync → rename),查询走 **pread**(低 RSS —— daemon 不 mmap、不整库驻留)。

```
┌──────────────────────────────────────────────────────────────────────┐
│ Header       magic b"DFDB0001" / version / counts / 各段 offset(u64) │
│ zstd dict    训练自本卷路径语料,整库一份                              │
│ Filename blk 每块 N 条路径,zstd 压缩(带字典) ← DocID 索引到这里      │
│ Filename idx u64 offset 数组:DocID → 块(随机定位)                    │
│ Trigram tbl  Robin Hood 哈希,2^k 槽:trigram→{off,len} 指向下面       │
│ Postings     TurboPFor(PFor delta,block=128,4 流交织)                │
│ Dir mtime    预留表(v1 no-op;为未来 df-watch readdir 复用挂钩)       │
└──────────────────────────────────────────────────────────────────────┘
```

- **trigram 语义**(REVIEW §7.7,**文件级**,非位置级):一条路径 = 一个 DocID。trigram = **小写化全路径**的字节滑动窗口 → 查询命中任意路径组件(`downloads` → `/Users/x/Downloads/...`)。
- **CJK 原生**:字节 trigram 直接处理 UTF-8 中文(3 字节/字),无需 jieba/pinyin(印证旧 `CTrigramIndex.h` 的结论)。
- **posting list** = 含该 trigram 的 DocID 升序去重 → delta 编码 → TurboPFor 位打包。块级解码,查询只解它碰到的那几条 list。

---

## 5. 查询算法(`df-core`)

```
1. 解析 query → boolean AST(terms + AND/OR/NOT + 括号)        [移植自 Swift]
2. 每个 term:
   a. 抽 query trigram(小写化 term 的滑动窗口)
   b. term 长度 ≥ 3:选最稀有 trigram → pread+解码其 posting list → 候选 DocID
      term 长度 < 3:扫文件名块(v1 可接受,后续优化)
   c. 每个候选 DocID:pread 文件名块 → zstd 解压 → 校验 term 是真实大小写不敏感子串 → 幸存
3. 按 AST 合并各 term 幸存集(AND 交集 / OR 并集 / NOT 差集)
4. 返回 DocID → 路径 → 流式输出
```

「最稀有 trigram 优先 + 子串校验」= plocate 路径(REVIEW §7.7、§6.1)。boolean AST 移植自现有 Swift `ParsedQuery`/`searchWithBooleanAST`(REVIEW §8.1 #2 强制)。

---

## 6. IPC 协议(`df-ipc`)

Unix domain socket,`LengthDelimitedCodec`(4 字节长度前缀)。socket 路径:`~/.deep-finder/daemon.sock`。消息 `serde` + `bincode`。

```
Request                     Response frames(daemon → CLI,流式)
────────────               ────────────────────────────────────────
Search {                    Batch  { paths: Vec<PathBuf>,
  query: String,                       meta: Vec<LiteMeta>,   // is_dir,size,mtime
  scope: Option<PathBuf>,              count_in_batch: u32 }
  limit: Option<u32>,        Done   { total: u32 }
  opts: SearchOpts }         Error  { message: String }
```

结果以 **batched stream**(每批 ~256 路径)返回,大批结果增量到达(同 fd,REVIEW §3.2)。CLI 边收边打印。

---

## 7. 数据流

### 7.1 索引(冷/全量)—— `deepfind index`(直接跑 df-index,无需 daemon)
```
ignore::WalkParallel(跳 .git/node_modules/target/build/...)
  → 采集 (path, is_dir, size, mtime) 每文件
  → trigramize 每条小写化全路径(DocID = 顺序)
  → 建 Robin Hood trigram 表 + 升序去重 posting list
  → 经 df-core 序列化:TurboPFor postings、zstd+字典 文件名块
  → 原子写:tmp → fsync → rename 到 ~/.deep-finder/db/<volume>.dfdb
```

### 7.2 查询(daemon 热路径)
```
CLI Search req → tokenize → boolean AST
  → 每 term:最稀有 trigram pread → TurboPFor 解码 → 候选 DocID
  → pread 文件名块 → zstd 解压 → 子串校验
  → 按 AST 合并(AND/OR/NOT)
  → 流式回 Batch 帧;Done{total}
```

### 7.3 `--direct` 兜底(CLI,daemon 不在/索引陈旧)
`ignore` 遍历 + 在线大小写不敏感子串匹配 → 直接打印。从不阻塞用户(REVIEW §7.9)。

---

## 8. CLI 界面(v1)

```
deepfind index [--root PATH] [--force]   建/重建 DB(默认 root = /,需 FDA)
deepfind <query> [--limit N] [--direct]  搜索(daemon;--direct = 在线直扫)
deepfind daemon                          跑 daemon(载 DB、监听 socket)
deepfind status                          daemon 健康 + DB 统计
```
裸 `deepfind <query>` = search 别名。daemon 缺失 → CLI 自动落 `--direct`(v1 不自动拉起 daemon)。

---

## 9. 错误处理

| 层 | 策略 |
|---|---|
| `df-core` | 类型化 `thiserror`:`DbFormat`/`Codec`/`Query`。纯,无 I/O。 |
| `df-index` | 遍历错误 → 跳过 + `tracing`(沿用 `ignore` 权限语义)。写错误 → 弃 tmp,绝不留半截库。 |
| daemon | accept loop + 每连接 `tokio` task。查询错 → `Error` 帧给客户端,**daemon 不倒**。panic 隔离在单连接。 |
| CLI | daemon 不可用/socket 错 → `--direct` 兜底 + `tracing` 提示。索引陈旧 → 同。 |

---

## 10. 测试

- **`df-core`**:TurboPFor 往返(随机 DocID 集 × 多尺寸)、Robin Hood 插入/查找/碰撞、DB 序列化/反序列化往返、查询算法(用 `&[u8]` 实现 `DbSource`)。`criterion` bench:编/解/交集 vs naive。
- **`df-index`**:遍历临时目录树 → 建 → 重开 → 断言已知路径可查 + 计数吻合。
- **`df-ipc`**:帧编/解码往返 + 模拟流式 batch。
- **`deepfindd`+`deepfind`**:端到端 —— 起 daemon(临时 DB)、跑 CLI 查询、断言结果 + `--direct` 兜底测试。
- 运行:`cargo test`(Swift 的 SIGSEGV 警告不适用,工具链不同)。CI 门:`cargo fmt --check`、`cargo clippy -D warnings`、`cargo test`。

---

## 11. Clean-slate 卸载(实现 Step 0)

### 11.1 源码/工程(整删)
`Sources/`(全部 Swift+C 模块 + entry)、`Tests/`、`Package.swift`/`Package.resolved`、`App/`、`.swiftpm/`、`.swift-format`、`.swiftlint.yml`、`.spi.yml`、`.xctestplan`、`.build/`、`PRODUCT.toml`;`.github/` 的 Swift CI(换 Rust CI);`scripts/` 里 Swift 专用脚本(逐个确认后删,如 `run-tests.sh`)。

### 11.2 运行时卸载(旧 Swift 残留)
- launchd:`launchctl bootout gui/$(id -u)/cn.com.nadav.deepfinder.daemon` + 删 `~/Library/LaunchAgents/cn.com.nadav.deepfinder.daemon.plist`
- 守护进程:读 `~/.deep-finder/session/daemon.pid` → SIGTERM
- 文件:`~/.deep-finder/session/ipc.sock`、`~/.deep-finder/cache/index.db{,-wal,-shm}`、`~/.deep-finder/logs/*`
- 旧二进制:`deepfinder` / `deepfinder-daemon` / `deepfinder-app`(`/usr/local/bin` 或 SPM build 目录或 Homebrew)
- **用户数据(完全清理)**:`~/.deep-finder/.env`、`settings.json`、`history`、`session/`、`cache/` 全删 → 整个 `~/.deep-finder/` 清空,Rust 版从干净状态重建

### 11.3 保留
`LICENSE`、`README.md`(改写为 Rust)、`SECURITY.md`、`SUPPORT.md`、`VERSION`;`.gitignore`(+`target/`)/`.gitattributes`/`.editorconfig`;`.claude/`/`.vscode/`;`search-analysis/`。

> 全部 git 可回滚(旧 Swift 已在提交历史里)。

---

## 12. 构建顺序(Approach A:纵向切片 → 硬化)

每步一个验证门;工作切片(**#4**)端到端跑通前不碰硬化。

| # | 步骤 | 验证 |
|---|---|---|
| 0 | **Clean slate**:删旧 Swift 工程 + 运行时卸载 + 起 Rust workspace 骨架 + CI | `cargo build` 干净;旧产物已清 |
| 1 | `df-core` 切片:格式骨架、**raw/varint** posting、`DbSource` 查询、trigram 抽取、子串校验 | 单测:索引 100 路径、查中子串 |
| 2 | `df-index` 切片:`ignore` 遍历 + 建最小 DB + 原子写 | 建临时树、重开、计数吻合 |
| 3 | `df-ipc` 切片:长度帧 req/resp + stub 查询 | 帧往返 |
| 4 | **`deepfindd` + `deepfind` 切片**(raw posting):daemon 出库、CLI 打印、`--direct` 兜底 | **端到端通过 → 工作切片** |
| 5 | 硬化 —— **自写 TurboPFor** 接入 df-core codec | 往返 + bench vs varint |
| 6 | 硬化 —— **Robin Hood 哈希**(替线性/排序) | 查找/碰撞测试 |
| 7 | 硬化 —— **zstd 文件名块 + 训练字典** | 压缩比 + 解码测试 |
| 8 | 硬化 —— **boolean 查询**(移植 Swift AST) | parser + eval 测试 |
| 9 | polish:dir-mtime 预留表挂钩、pread RSS 上限、README/文档 | build 干净、bench 跑通 |

---

## 13. 存储布局(运行时)

```
~/.deep-finder/
├── daemon.sock              # Unix socket
├── db/
│   └── index.dfdb           # v1 单文件(启动卷);未来多卷 → <volume>.dfdb 分片
└── logs/                    # daemon/CLI 日志
```
(整目录由 clean slate 清空后,Rust 版重建。)

---

## 14. 未来(明确不在本轮)

- v2 内容索引:Zoekt 式位置 trigram + varint + mmap shard
- `df-watch`:notify(FSEvents)+ per-file 增量合并 posting list(补 reflex 假增量)
- GUI:如需,作为连 Rust socket 的薄客户端重做
- 拼音/jieba 中文增强(字节 trigram 已 CJK 可用)
- daemon 自动拉起(launchd RunAtLoad)
- 多卷自动分片 + 跨 shard 并行查询

---

## 15. 验收标准(本轮完成的定义)

1. `cargo build` / `cargo fmt --check` / `cargo clippy -D warnings` / `cargo test` 全绿。
2. `deepfind index` 能建出启动卷的 `.dfdb`(文件级 trigram + TurboPFor + zstd + Robin Hood)。
3. `deepfind <query>` 经 daemon 返回正确结果;`--direct` 兜底可用。
4. boolean(AND/OR/NOT)查询正确(parser + eval 测试通过)。
5. 端到端测试覆盖 daemon+CLI;`df-core` 有 criterion bench。
6. 旧 Swift 工程与运行时**完全清除**,仓库为纯 Rust;`~/.deep-finder/` 从干净状态重建。
