# DeepFinder — 终局模型技术选型

> **状态**:2026-06-24 更新。本表为**终局(end-state)目标**;2026-06-23 的「完整实现」(Phase A–F)已交付其中若干项(见 ✅ 标注),其余 ⏳ 仍待实现。基于两份锁定设计 spec(`docs/superpowers/specs/2026-06-22-rust-search-index-cli-design.md`、`…-v2-content-index-design.md`)推导。
> **一句话**:**终局 = 已建成基线 + v2.1 增量层 + M7 硬化层**;全量重建只是 v2.0 里程碑,不是终态。
> **配套文档**:[architecture.md](architecture.md)(已建成架构图,反映 `main` 实际代码)。

---

## 图例

| 标记 | 含义 |
|---|---|
| ✅ | 已建成并验证(代码在 `main`) |
| ⏳ | 已锁定设计,代码未建(v2.1 / M7)——这正是"终局相对今天"的增量 |

---

## 1. 语言与工程基线(全建成)

| 维度 | 终局选型 | 状态 | 为什么选这个 |
|---|---|---|---|
| 实现语言 | **Rust**(edition 2021,resolver 2) | ✅ | 搜索热路径要 C 级控制(mmap/pread/零拷贝)+ 内存安全(无 GC 停顿、无 UB)。原 Swift 工程于 2026-06-22 整体重写 |
| 工程组织 | **6-crate 单向无环 workspace** | ✅ | 分层解耦;关键是 **df-core 零 I/O**——引擎对 `DbSource` trait 操作,可脱离真实 DB 单测 + bench |
| 序列化 | **serde + bincode**,全字段 `#[serde(default)]` | ✅ | 紧凑二进制(无 JSON 文本开销)+ 新旧端互通(前向/后向兼容) |

---

## 2. 存储模型

| 维度 | 终局选型 | 状态 | 为什么选这个 |
|---|---|---|---|
| 总体 | **双层独立存储 + 一个候选引擎** | ✅ | 文件名层与内容层访问剖面不同 → 分存;但**算法统一**(共享 `CandidateSource` trait)避免双引擎 |
| 文件名层 | `.dfdb` 单文件,**全 pread** | ✅ | 低延迟低 RSS:pread 只读命中 posting,daemon 不整库驻留 |
| 内容层 | `.dfcs` 多 shard,**全 mmap**(memmap2 MAP_SHARED PROT_READ) | ✅ | GB 级内容,内核 page cache 管 residency——不碰的页不占内存、零拷贝 |
| 格式演进 | zoekt 式 **tagged-TOC + footer 8B 定位** | ✅ | 自描述 + 前向兼容(未知 tag 跳过);读末 8B 即定位 TOC |
| 内容语料 | **raw bytes**(zoekt 式,~1× 磁盘预算) | ✅ | verify 最快;磁盘预算换速度(已接受,1 MB/文件上限封顶) |
| 文件名压缩 | zstd + **训练字典** + 块索引 | ✅ | 路径高度冗余,字典压缩比远超通用 zstd;块索引支持随机解压 |
| docid 模型 | 全局 u32 + `base_docid` 映射 | ✅ | 两层结果可直接按**路径键 union 去重**,无需跨层 join |
| **shard 集** | `ArcSwap<Vec<Arc<Shard>>>` **无锁原子快照** | ✅ | 重建期无停机换 shard;旧 `Arc` drain 后落(F1 交付,实测 rename-over 保 inode 防 SIGBUS) |
| **scope 剪枝** | `dirTable` + 每文档 `u16 dir_id` → shard 级跳过 | ⏳ | 现 `--scope` 是查后路径过滤;终局能跳过整个 shard |

---

## 3. 引擎算法(df-core)

| 维度 | 终局选型 | 状态 | 为什么选这个 |
|---|---|---|---|
| 索引粒度 | **字节 trigram**,双射 u32 键(见下) | ✅ | 键零碰撞 + CJK 原生(UTF-8 多字节直接成窗,无需分词器) |
| **trigram 表** | **ASCII 直索引数组(2M 槽,~16MB/shard)+ 非 ASCII Robin Hood tail** | ⏳ | 全盘内容绝大多数 ASCII → 走**零哈希快路径**;非 ASCII tail 复用 RH(20B 槽) |
| **候选生成(终局)** | **2-rarest 交集**(两指针 on sorted TurboPFor-decoded deltas) | ⏳ | 高频 trigram(`the`/`com`/`src`)退化时,2-rarest 把候选集进一步收窄 |
| 候选生成(基线) | single-rarest → verify | ✅ | 现状:正确但非最快 |
| 精确校验 | `memchr::memmem`(content)/ `windows==`(filename) | ✅ | 一次精确子串剔光 trigram 误报;memchr 走 SIMD 快路径 |
| 倒排压缩 | **自写 TurboPFor**(PFor delta,block=128,**标量无 SIMD**) | ✅ | docid posting 近似单调整数 → 高压缩比 + 快解码;自写换**纯 Rust(无 FFI)+ 标量可移植** |
| 哈希表 | **Robin Hood 开放寻址**,splitmix32,20B/槽 | ✅ | 无指针追逐 → 缓存友好;Robin Hood 限最差探测长度 → 查询可预测 |
| **<3 字节查询** | **bigram 索引(65k 数组)**;1 字符 refuse/cap | ⏳ | 现 <3 字节线性扫全库 |
| 大小写 | 默认 **smart-case**,`-i`/`-s` 覆盖 | ✅ | 小写当模糊搜、大写当精确搜,匹配 fd/ripgrep 直觉 |
| 复杂查询 | **boolean AST**(AND/OR/NOT + 括号 + 隐式 AND) | ✅ | zoekt 风格表达力 |
| trigram 语义 | **文件级(非位置)+ 子串校验** | ✅ | 刻意偏离 REVIEW §7.2(推荐位置 trigram);用 rarest + 2-rarest + bounded-verify 对冲退化 |

**字节 trigram 键**(双射 u32,零碰撞):

```
key = (a << 16) | (b << 8) | c        // 三字节 a,b,c 滑动窗口 → u32
索引侧:对小写化字节滑窗抽 key
查询侧:对 folded query 抽 key → 取 posting 最短者
```

---

## 4. 更新模型 ← 终局的关键升级

| 维度 | 终局选型 | 状态 | 为什么选这个 |
|---|---|---|---|
| **更新模型** | **增量:`df-watch`(`notify`/FSEvents watcher)→ `rebuild_and_swap` + ArcSwap 热换** | ✅(部分) | watcher + 无停机热换**已交付**(F4);但每次变更是**全根重扫**,非每文件 posting 合并(高风险,未做) |
| 全量重建 | v2.0 基线(留存) | ✅ | 简单可靠;保留作 `--force` 兜底 |
| 增量挂钩 | dir-mtime 表(F2)+ MANIFEST 签名(F3) | ⏳(延后) | 正确性中性——全根重扫与全量重建等价;钩子在 `crates/df-core/src/db.rs`(dirmtime_off 预留)。需大语料基准才值得 |
| 重建换 shard | 写新文件 → `ArcSwap::store` → drain 后删旧(旧 shard 先 **rename-aside**) | ✅ | 无离线窗口;rename-aside(非直接 unlink)防 mmap SIGBUS(F1 实测) |

> **设计锁定结论**(spec):v2.0 = full rebuild(user-locked);incremental = v2.1。终局目标是增量,但**架构故意预留钩子**使其不被堵死。**现状(2026-06-24)**:v2.1 的 watcher 增量(rebuild_and_swap + ArcSwap 热换)已交付;真正的每文件 posting 合并仍留作更后。

---

## 5. 进程模型 / IPC / mmap

| 维度 | 终局选型 | 状态 | 为什么选这个 |
|---|---|---|---|
| 部署 | **常驻 daemon + 薄 CLI** | ✅ | daemon 持索引句柄(不重开大 mmap)→ 快速重复查询 |
| 传输 | **Unix domain socket** + LengthDelimitedCodec(4B 长度前缀) | ✅ | 本地专用、无网络暴露、低延迟、可传凭证 |
| 结果传输 | **流式 Batch×N(512/帧)+ Done** | ✅ | 万级结果不阻塞——增量返回,CLI 边收边打 |
| 兜底 | daemon 不可用 → CLI 自动 `--direct` 在线扫 | ✅ | 永不阻塞用户;graceful degradation |
| **madvise** | hash/postings `MADV_RANDOM`;ASCII 数组 resident;冷区 `MADV_DONTNEED` | ⏳ | RSS 控到"几十 MB + 16MB/shard ASCII 数组" |
| **per-shard 并行** | CPU-capped 并行查询 | ⏳ | 现在内容查询顺序循环,大 shard 数时延迟线性增长 |

---

## 6. 刻意不在终局(明确排除)

| 项 | 为什么排除 |
|---|---|
| 位置 trigram / 短语 / 邻近搜索 | 文件级 + 子串 verify 够用;位置级成本高,v2.1 或更后才重评 |
| 相关性排序 | 可选(路径深度 + match-kind 加权),非核心 |
| SIMD 解码 | 标量正确优先;SIMD 为可选优化 |
| 多卷自动分片 / resumable cursor / GUI / pinyin-jieba | 本轮范围外 |

---

## 状态汇总

| 层 | ✅ 已建 | ⏳ 终局未建 |
|---|---|---|
| 语言/工程 | 3/3 | — |
| 存储 | 8/9 | dirTable 剪枝 |
| 引擎 | 8/11 | ASCII 直数组、2-rarest(实测回退)、bigram |
| 更新模型 | watcher+热换+全量重建 ✅;每文件合并未做 | dir-mtime(F2)、MANIFEST 签名(F3)、每文件 posting 合并 |
| 进程/IPC/mmap | 4/6 | madvise、per-shard 并行 |

**判定**:核心引擎 + 进程模型 + 双层存储**已建成且正确**;增量更新的 watcher+热换层亦已交付。终局剩余工作集中在两块——**(1) 真增量(每文件合并 / dir-mtime / 签名)**、**(2) 性能硬化层(M7)**。两者都是**已锁定设计、架构不堵死**,只待实现(D2 经测量本轮未留一项,需大真实语料重评)。

---

## 收敛(一句话)

> **进度(2026-06-24)**:无锁 shard 热换(ArcSwap,F1)+ df-watch 增量(watcher→`rebuild_and_swap`,F4)**已交付**,把「全量重建」升级为「变更触发重扫 + 热换」。**仍待实现**:每文件 posting 合并、dir-mtime 增量(F2)、MANIFEST 签名(F3),以及 M7 硬化(ASCII 直数组 / 2-rarest 已实测回退 / bigram / dirTable / madvise / per-shard 并行)——D2 经测量本轮未留一项,需大真实语料重评。架构靠 `db.rs` 预留钩子**不堵死**,只差实现。
