# Index 引擎重构 — 设计

**日期**: 2026-06-20
**状态**: Draft(待 review)
**范围**: 重构 DeepFinder 的索引后端,对标两个开源参考(Cling = macOS 原生 Everything;FSearch = C 版 Everything 克隆)。核心目标:**单分配 entry + 字符串去重 + 修两个潜在 bug + 用二进制格式替换 SQLite 持久化**。**保留** Trie + FullSubstringMap + trigram 查询路径(经核实比两个参考都强)。

参考项目已 clone 到 `~/IdeaProjects/references/{Cling,fsearch}`,4 个 agent 精读 + 1 个 agent 核实当前 CIndex 真实状态。本设计所有结论均带 file:line,经交叉验证。

---

## 1. 背景与根因

### 1.1 当前 CIndex 真实状态(逐行核实)

**每条记录 5 次 malloc**(非此前调研所说的 6):
| # | 位置 | 分配 |
|---|---|---|
| 1 | `CIndex.c:307` | `m->original_name = strdup(...)` |
| 2 | `CIndex.c:308` | `m->path = strdup(path)` |
| 3 | `CIndex.c:309` | `m->parent_path = strdup(...)` |
| 4 | `CIndex.c:177`(`path_insert` 内) | `idx->path_hash[h].path = strdup(path)` |
| 5 | `CIndex.c:222`(`name_insert_at` 内) | `idx->names[pos].name = strdup(name)` |

trigram posting 是摊销 arena realloc(`CTrigramIndex.c:84,98,113`),非每条记录。

**字符串冗余**:
- 文件名 **3 份**:NameSlot 小写(`CIndex.c:222`)+ FileMeta 原始(`CIndex.c:307`)+ trigram arena 小写(`CTrigramIndex.c:312-316`)
- 路径 **2 份**:path-hash 槽(`CIndex.c:177`)+ FileMeta(`CIndex.c:308`)
- 无 intern / 去重
- 每条记录 ~440B(160B 字符串 + 88B 结构 + 88B 分配器 + 100B trigram)

### 1.2 两个潜在 bug(独立于布局,都必须修)

| Bug | 位置 | 影响 |
|---|---|---|
| **B1: path hash 不扩容** | `CIndex.c:164` 空 `if` 体,注释「not implemented」 | 开放寻址 + FNV-1a + 线性探测,固定容量 `PATH_HASH_CAP=262144`(`CIndex.c:38`)。负载因子 >0.5 不扩容 → 探测链无限增长;**满表插入死循环**。>128K 唯一路径触发,~200K 文件规模必现 |
| **B2: `find_meta_by_id` 是 O(n) 线性扫** | `CIndex.c:483-488` | **无 id→idx 映射**。每个 `cindex_get_path/_name/_parent/_size` 全表扫一遍。搜 100 条结果 × 200K 文件 = **2000 万次扫描**回填 FileRecord |

### 1.3 持久化现状(核实后比 CLAUDE.md 描述简单)

- `~/.deep-finder/cache/index.db`,WAL,权限 600,两张表:`file_records`(11 列,含 `metadata_json`)+ `metadata`(KV:`event_cursor`、`path_encryption` flag),schema v3
- **PathEncryption 是纯数据层**:AES-256-GCM 套在 path/parent_path 列(`IndexPersistence.swift:256-267` 写、`:494-510` 读),密钥 256-bit 存 SecretsStore(`PathEncryption.swift:77`)。**与 SQLite 列零耦合** → 二进制字段过同一加解密即可
- **SecretsStore 独立**(`~/.deep-finder/.env` 扁平 JSON),**不碰 index.db** → 替换零影响
- **FSEvents 增量当前根本不落盘**(只存 cursor)。持久化仅两处:首扫完成 `saveRecords`(`DaemonMain.swift:780`)+ stopWatching 存 cursor(`FSEventWatcher.swift:207`)。CLAUDE.md 的「每 5s/100 条」是历史规划、**代码未实现** → 写模式极简(全量重写 + cursor + 按 id 增删)
- IndexPersistence 公共 API 6 个调用点(`DaemonMain.swift:449,455,476,500,780,834`),**签名可保持不变** → 透明替换

### 1.4 两个参考项目的真实启示

**FSearch(C)**:
- 单 `calloc`/entry,flexible array member 内联 name(`fsearch_database_entry.c:29-38,742-801`)→ **1 malloc/entry**。path 不存,靠 parent 指针链重建(我们**不抄**这个)
- **没有 Trie/trigram** — 子串搜索靠 `strstr`/PCRE2 **线性扫所有 entry** O(n),按核并行(`index_store_search` `:1260-1315`)
- **持久化排序索引 + 前缀压缩名**(`fsearch_database_file.c:748-786`)→ 启动不重排,原子 tmp+rename
- 单线程扫描,每项一次 `fstatat`(与当前 stat 成本相同,无可借鉴)

**Cling(Swift)**:
- SoA 并行数组(每记录 ~30B 固定开销,零 malloc),UInt64 bitmask 预过滤 + SIMD8 + concurrentPerform(`SearchEngine.swift:2585-2591,161`)
- **bitmask 是必要不充分**(Bloom-like,「aba」mask==「ab」),39 位(a-z/0-9/.-\_),**中文进不了 bitmask** 靠 Phase2 byte 评分兜底
- `.idx`「mmap」是营销话术:`Data(.mappedIfSafe)` 读后 **memcpy 到堆数组**,**无 madvise/MADV_FREE**(全仓 grep 仅命中注释)。README「swappable」= 关窗口释放 engine 重开重读
- FSEvents 做主索引增量;MDQuery(Spotlight)**仅用于 Recents**(最近 7 天),非避免全量重扫

**🔍 关键判断**:DeepFinder 的查询路径(Trie + FullSubstringMap + trigram)是 O(1)-ish 子串搜索,**比两个参考都强**(它们都是 O(n) 线性扫)。**重构不应换搜索算法**(会把 O(1) 退化成 O(n),中文还进不了 Cling bitmask)。真正该抄的是它们的**存储纪律**:单分配、字符串去重、持久化索引秒开。

---

## 2. 目标与非目标

### 2.1 目标

- **G1**:每条记录 **1 次分配**(5 malloc → 1),内联 name
- **G2**:字符串去重 — 文件名 3→≤2,路径 2→1
- **G3**:**修 B1** path hash 扩容(负载因子 >0.5 翻倍 + rehash),大索引正确性
- **G4**:**修 B2** `find_meta_by_id` → O(1) id→idx 直接映射
- **G5**:用二进制格式 `index.bin` **替换 SQLite**,启动免 row 解码、加载快;承载 metadata + path 加密 + FSEvents cursor + 版本号
- **G6**:**保留** Trie + FullSubstringMap + trigram 查询路径不动(子串 O(1)-ish 优势)
- **G7**:一次性 SQLite→二进制迁移,旧库数据无损转出

### 2.2 非目标

- ❌ 抄 Cling 的 SoA 并行数组 + bitmask 线性扫搜索(查询退化、中文不进 bitmask)
- ❌ 抄 FSearch 的 parent 指针链重建 path(牺牲每次访问 O(depth),违背「speed #1」)
- ❌ mmap 常驻 / madvise 换出(Cling 自己也没真做)
- ❌ MDQuery / Spotlight 依赖(违背零外部依赖原则;Cling 也只用于 Recents)
- ❌ 改查询语法、改 GUI、改 IPC 协议(透明替换,外部接口不变)

---

## 3. 架构决策

### 3.1 单分配 entry(FSearch 式 flexible array member)

新建 C 结构(替换当前 FileMeta + NameSlot + PathSlot 三件套):

```c
typedef struct {
    uint32_t id;            // 同时是 id→idx 映射的键(修 B2)
    uint32_t parent_id;     // 仅存关系;不用于重建 path(见 3.2)
    uint64_t size;
    int64_t  mtime, ctime;
    uint32_t attr_flags;    // bitmask:哪些可选属性在位(FSearch 思路)
    uint16_t flags;         // isDir 等
    uint16_t name_len;      // 内联原始 name 字节数
    /* 后跟内联数据,连续无 malloc */
    uint8_t  data[];        // [name 原始][path][parent_path][可选 metadata]
} DFileMeta;
```

一次 `calloc(sizeof(DFileMeta) + name_len + path_len + parent_len + meta_len)`。Trie/trigram 指针指向 entry 内 name,不再各自 strdup。

### 3.2 Path 全路径内联一份(不做 parent-chain)

`路径 2→1`:干掉 path-hash 槽里的冗余副本,DFileMeta 内保留**一份**完整 path。**不抄** FSearch parent 指针链重建 — 那是省内存换每次访问 O(depth)。项目原则「memory 不是约束、speed #1」+ GUI/IPC 每条结果都要 path → **用内存换 O(1) path 访问**。

### 3.3 Filename 去重(3→≤2)

- **一份原始大小写**(entry 内联 name,显示 + original_name 用)
- **一份小写 buffer**:Trie 和 trigram 共享同一份小写视图(当前各自存一份)。具体「按需生成+缓存」还是「内联一份小写副本」在 plan 阶段定(plan 须给出小写 buffer 如何被 Trie 节点和 trigram arena 同时引用,避免又变两份)

### 3.4 id→idx 直接映射(修 B2)

新增 `DFileMeta **id_index`(直接映射数组;id 紧凑则 `id_index[id]` 直接索引,稀疏则加一层)。所有 `cindex_get_*` 改走直接映射,O(1)。`find_meta_by_id` 线性扫删除或仅留作调试。

### 3.5 path hash 扩容(修 B1)

实现 `CIndex.c:164` 空体:负载因子 >0.5 → 容量翻倍 + rehash 全表。阈值常量化、加测试覆盖「插入 >2× 容量路径不死循环、查找不退化」。

### 3.6 二进制格式替换 SQLite

新 `BinaryIndex` 模块替换 `IndexPersistence` **实现**,保留全部公开 API 签名(透明)。理由见 §1.3:PathEncryption 可移植、SecretsStore 独立、写模式极简、调用点少。详见 §7。

### 3.7 为何不选其他方案(记录否决理由)

- **Cling SoA + bitmask**:子串查询 O(1)→O(n) 退化;39-bit bitmask 中文进不去 → 否决
- **parent-chain path**:每次 path 访问 O(depth),违背 speed #1 → 否决
- **mmap 常驻**:Cling 自己也只是 memcpy 到堆、无 madvise,收益不实 → 否决
- **保留 SQLite + 二进制 warm-cache**:用户已选「替换」,且写模式极简、资产可迁移 → 采纳替换(见 §7)

---

## 4. 组件设计

### 4.1 `DFileMeta`(C,`Sources/CIndex/src/`)

单分配 entry 结构(见 §3.1)。提供:
- `dmeta_create(id, parent_id, name, path, parent_path, size, mtime, ctime, flags, metadata?)` — 一次 calloc
- `dmeta_free` — 一次 free
- 内联字段访问器(name/path/parent_path/metadata)

### 4.2 id→idx 映射(`CIndex.c`,修 B2)

- 直接映射数组 `DFileMeta **by_id`,容量随 max_id 增长
- `cindex_insert` 同步登记;`cindex_remove` 同步清空(注意 swap-with-last 的 id 复用 → 见 R4)
- 所有 `cindex_get_*` 改走 `by_id[id]`,O(1)

### 4.3 path hash 扩容(`CIndex.c:164`,修 B1)

- 负载因子 >0.5 → `calloc` 翻倍新表 → 遍历重插 → free 旧表
- 初始容量保留 262144(小库无 rehash 开销),上限随库增长

### 4.4 字符串去重(Trie / trigram / name)

- Trie 节点不再 strdup name — 引用 entry 内 name 的小写视图
- trigram arena 不再单独存小写副本 — 共享同一份(或由 plan 决定共享机制)
- 原 NameSlot 的 strdup(`CIndex.c:222`)删除

### 4.5 `BinaryIndex`(新建,`Sources/Persist/BinaryIndex.swift`,替换 IndexPersistence 实现)

保留 IndexPersistence 公共 API(`init`/`loadAllRecords`/`saveRecords`/`deleteRecords`/`deleteRecordsByPathPrefix`/`saveEventCursor`/`loadEventCursor`/`flush`/`close`),内部换成二进制读写。DaemonMain/FSEventWatcher 6 个调用点透明。

### 4.6 SQLite→二进制迁移(一次性)

新版首启:`index.bin` 不存在但 `index.db` 存在 → 用旧 IndexPersistence(降级为只读迁移器)读 SQLite v3 → 写 `index.bin` → 之后只用二进制。`PathEncryption` 密钥不变 → 旧密文原样转写(或迁移时解密重加密,二选一,plan 定)。

### 4.7 MetadataStore 合流

二进制 entry 自带 metadata 字段 → 替代 SQLite `metadata_json` 列。已提交的元数据过滤设计(`2026-06-19-metadata-filter-restore-design.md` §7)的持久化基底从 SQLite 改为二进制,语义不变。MetadataStore.loadPersisted 改从二进制读。

---

## 5. 数据流

```
启动:    index.bin ──bulk read──▶ parse entries ──▶ 重建 Trie(便宜)
                                                      + trigram:有 postings 则装载,无(posting_bytes=0)则从 entries 重建
                                                      + MetadataStore 读 metadata 字段
         (首次迁移)index.db ──旧 reader──▶ entries ──▶ 写 index.bin
扫描完成: DaemonMain:780 ──saveRecords──▶ 序列化 entries + postings ──▶ index.bin.tmp ──rename──▶ index.bin
FSEvents: 增量 ──▶ 仅更新内存索引(当前行为,不落盘)
关闭:     stopWatching 存 cursor ──▶ index.bin 尾部 KV ──▶ fsync
```

---

## 6. 并发、原子性与迁移

- **单写者 = daemon**。无并发写,无需 WAL
- **原子写**:全量写 `index.bin.tmp` → `fsync` → `rename`(FSearch 模式)。崩溃留下完整旧文件或完整新文件,无半截
- **版本**:header magic `DFIX1` + version u16。版本不兼容 → 当作损坏,删 `index.bin` 全量重扫(等价当前 IndexRecovery 的「删除重建」语义,`IndexRecovery.swift:220-224` 改副文件名)
- **迁移**:一次性,见 §4.6。迁移失败回退 SQLite 读 + 标记重试,不丢数据

---

## 7. 二进制格式规范

```
┌─ Header ────────────────────────────────────────────────┐
│ magic      "DFIX1"        4B                            │
│ version    u16            (=1)                          │
│ flags      u8             bit0: path_encrypted          │
│                          bit1: endian(little)           │
│ reserved   u8[3]                                        │
│ num_files      u32                                     │
│ num_folders    u32                                     │
├─ KV metadata ───────────────────────────────────────────┤
│ kv_count   u32                                         │
│ [key_len u16 | key | val_len u32 | val] × N            │  ← event_cursor 等
├─ Entries ───────────────────────────────────────────────┤
│ [ DFileMeta fixed 头                                     │
│   + name(原始,name_len)                                │
│   + path(path_encrypted? 密文 : 明文)                  │
│   + parent_path(同上)                                  │
│   + meta_len u32 + metadata bytes(无则 meta_len=0) ]   │
│   × num_files+num_folders                              │
├─ Trigram postings(预计算;可选)────────────────────────┤
│ posting_bytes u32   (=0 表示未持久化,加载时从 entries 重建)│
│ [ blocks + postings + arena 的二进制序列化 ]            │
└─────────────────────────────────────────────────────────┘
```

- **加载**:bulk read 全文件到内存 → 按 offset 解析。Trie 从 entries 重建(便宜,纯内存 bulk insert);**trigram postings 直接装载**(跳过 O(n) 重建,这是启动加速主因)
- **写入**:`saveRecords` 序列化 entries + 当前 postings → tmp → rename
- **加密**:path/parent_path 过 PathEncryption(header flags 标记)。其余字段明文(与当前 SQLite 一致)。`deleteRecordsByPathPrefix` 在加密开启时仍退化为「读全部→解密→内存过滤」(GCM nonce 让前缀匹配失效,与当前 `IndexPersistence.swift:371-400` 同策略)

---

## 8. spec 影响(需求变更,走 REQ_CHANGE_LOG)

1. **`REQ_CHANGE_LOG.md`**:新增 `CHG-2026-06-20-01`,记录「索引后端重构:单分配 entry + 字符串去重 + 修 B1/B2 + 二进制替换 SQLite」。来源(对标 Cling/FSearch)、影响 REQ(`v0.1-index-core` 索引核心 + 持久化相关 REQ)、变更类型(架构重构)
2. **`v0.1-index-core.md`** 及涉及持久化的 REQ 文件:内联状态/实现溯源更新(InMemoryIndex/FileRecord/Trie/FullSubstringMap/TrigramIndex 的实现从 SQLite-backed 改为 binary-backed)
3. **元数据过滤设计合流**:`2026-06-19-metadata-filter-restore-design.md` §7 持久化基底从 SQLite `metadata_json` 改为二进制 entry metadata 字段;MetadataStore.loadPersisted 目标更新。两设计本应一套
4. **`CLAUDE.md`**:
   - `## Architecture` 持久化段:SQLite WAL → 二进制 `index.bin`(magic/version/原子 rename)
   - `## Gotchas`:`index.db`/`-wal`/`-shm` socket 清理类描述改为 `index.bin`
   - 移除「每 5s/100 条批量写」描述(代码本就未实现)
5. **`Package.swift`**:Persist 是 SQLite3 唯一用户,迁移完成后核实是否移除 SQLite3 linker setting(保留旧 reader 迁移期不删)
6. **`00-overview.md` / `REQ_STATUS.md`**:若统计「持久化方式」相关项,同步

> 实现顺序:先改 spec(本设计批准后),再 TDD 实现(分阶段 §9),最后更新 REQ 内联状态图标。

---

## 9. 测试策略(TDD,先 failing)

| 阶段 | 测试 | 覆盖 |
|---|---|---|
| **P0 修 bug** | `CIndexHashResizeTests`(C 侧或 Swift 桥) | B1:插入 >2× 容量路径不死循环、查找不退化、rehash 后路径仍唯一;B2:大库 `cindex_get_*` O(1)(measure 基准) |
| **P1 entry 布局** | `DFileMetaTests` | 单分配计数(strdup 0 次)、内联 name/path/metadata 读写、free 无泄漏、Unicode/emoji/CJK |
| **P2 去重** | `IndexDedupTests` | filename 3→≤2(内存计量或分配计数)、Trie/trigram 共享小写 buffer 正确性不退化(现有 Trie/Trigram 测试全绿) |
| **P3 二进制** | `BinaryIndexTests` | round-trip(写后读全字段一致)、原子写(中断留完整旧文件)、版本不兼容→删重建、加密 on/off path 字段、cursor 往返、metadata 字段往返 |
| **P4 迁移** | `SQLiteMigrationTests` | 旧 SQLite v3 → index.bin 无损(含加密库)、迁移失败回退、重复迁移幂等 |
| **P5 集成/回归** | 现有 `IndexTests`/`PersistTests`/`DaemonTests`/`FSTests` | 全绿;启动→搜索→关闭全链路;`IndexRecovery` 删除重建语义保留 |
| **性能** | `measure` | 启动加载(1M entries)vs 旧 SQLite 基线;`cindex_get_*` 大库 O(1);单记录分配次数 |

---

## 10. 风险与权衡

- **R1 二进制格式损坏**:自研格式 bug 可能写坏索引。缓解:原子 tmp+rename(损坏只影响新文件,旧的完整)+ 版本/校验 + 不兼容即删重建(全量重扫兜底,等价当前 recovery 语义)
- **R2 迁移数据丢失**:SQLite→二进制迁移出错丢索引。缓解:迁移失败回退 SQLite 读 + 标记重试;迁移期保留旧 IndexPersistence 只读代码;迁移产物校验(记录数一致)
- **R3 trigram 序列化复杂**:trigram 内部结构(arena/spans/postings/blocks/pending)二进制化易错。缓解:先持久化 entries 重建 trigram(简单正确)作为 fallback,trigram postings 持久化作为优化层独立验证;若序列化风险高则 P3 只持久 entries
- **R4 id 复用**:C 索引 `cindex_remove` 用 swap-with-last,id 可能复用 → metadata/id_index 必须在 remove 时同步清空,且 extract 前用 path 校验,防 A 文件 metadata 挂到复用其 id 的 B 文件(与元数据设计 R4 同源,plan 须先验证 id 生命周期)
- **R5 路径唯一性**:`path UNIQUE` 约束当前由 SQLite 保证、启动去重依赖(`DaemonMain.swift:459-477`)。二进制写入侧需保证唯一(写入时去重或迁移时规整)
- **R6 加密前缀删除**:`deleteRecordsByPathPrefix` 加密开启时退化为全读解密过滤(当前已有此限制,二进制继承,非新增风险)

---

## 11. 交叉引用

- **参考项目**:`~/IdeaProjects/references/Cling`(macOS 原生)、`~/IdeaProjects/references/fsearch`(C Everything 克隆)
- **依赖的 REQ**:`specs/reqs/v0.1-index-core.md`(索引核心)、持久化相关 REQ(plan 阶段定位具体 REQ 号)、`specs/reqs/v2.1-media-metadata.md`(REQ-2.1-06/07,元数据合流)
- **依赖的设计文档**:`specs/design/2026-05-26-deep-finder-design.md`(索引架构、daemon 数据流)、`specs/2026-06-19-metadata-filter-restore-design.md`(§7 持久化基底合流)
- **实现计划**:本设计批准后由 writing-plans 产出,路径 `superpowers/plans/2026-06-20-index-engine-refactor-plan.md`(待定)
- **相关代码**:`Sources/CIndex/src/{CIndex,CTrigramIndex}.c`、`Sources/Index/{InMemoryIndex,FileRecord}.swift`、`Sources/Persist/{IndexPersistence,SchemaMigrator,IndexRecovery,PathEncryption,SecretsStore}.swift`、`Sources/Daemon/DaemonMain.swift`、`Sources/FS/FSEventWatcher.swift`
