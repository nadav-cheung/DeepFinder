# 媒体元数据过滤修复 — 设计

**日期**: 2026-06-19
**状态**: Draft(待 review)
**范围**: 把 `width:`/`height:`/`duration:`/`artist:`/`pages:` 等媒体元数据过滤从「死功能」修复为可用,方式是将原计划延期到 v3.1 的「后台批量提取」(REQ-2.1-06 AC5)提前到现在实现。

---

## 1. 背景与根因

### 1.1 现象

`SearchFilter` 已完整实现元数据过滤(`SearchFilter.swift:129-144`,读 `record.metadata?.fields[field]`),`FilterPipeline.parse` 也已接好 `width/height/duration/pages/fps/bitRate/artist/album/title/genre/codec` 等修饰词(`FilterPipeline.swift:75-81`)。但所有元数据过滤**永远返回 false**,因为 `record.metadata` 恒为 `nil`。

### 1.2 根因(已逐层核实)

1. **SQLite 层完全 ready**:v2 schema 有 `metadata_json TEXT` 列(`SchemaMigrator.swift:38,113`),`IndexPersistence` 写入时 `record.metadata` → JSON 编码 bind(`IndexPersistence.swift:284-290`),`recordFromStatementRaw` 读取时解码回 `ExtractedMetadata`(`SchemaMigrator.swift:284-301`)。
2. **断点在 C 索引**:索引后端已迁移到 C(`InMemoryIndex` 包 `CIndex`)。`cindex_insert` / `_lookup`(`InMemoryIndex.swift:388-399`)重建 `FileRecord` 时**没有 metadata 字段可填**——C 的 `FileMeta` 不存元数据。所以无论 SQLite 有没有数据,搜索路径的 `FileRecord.metadata` 恒 nil。
3. **无提取触发**:spec `REQ-2.1-06 AC5` 把「索引构建阶段后台批量提取」明确**延期至 v3.1**。当前没有任何代码路径会把媒体元数据写入索引或 SQLite,因此 `metadata_json` 列在实际运行中始终为空。

> 结论:这是「管线已搭好但两端都断」——读端(C 索引不回填)+ 写端(无提取触发)。修复必须同时接通两端。

### 1.3 已确认在位的资产(本次复用,不重造)

| 资产 | 位置 | 状态 |
|---|---|---|
| `FileRecord.metadata: ExtractedMetadata?` 字段 | `FileRecord.swift:45` | ✅ 在位 |
| `ExtractedMetadata` / `MetadataValue`(Codable/Sendable) | `ExtractedMetadata.swift` | ✅ 在位 |
| 4 个 extractor(image/audio/video/PDF) | `Sources/Media/*` | ✅ 在位 |
| `MetadataExtractorRegistry`(扩展名分发 + `allSupportedExtensions`) | `MetadataExtractor.swift` | ✅ 在位 |
| `SearchFilter.metadataMin/Max/Range/Match` | `SearchFilter.swift:129-144` | ✅ 在位(读端逻辑正确) |
| `FilterPipeline.parse` 元数据修饰词 | `FilterPipeline.swift:75-81` | ✅ 在位 |
| SQLite `metadata_json` 列 + 读写 | `IndexPersistence.swift`, `SchemaMigrator.swift` | ✅ 在位 |
| `MetadataLoader`(GUI 详情按需提取 + per-path 缓存) | `MetadataLoader.swift` | ✅ 在位(GUI 用,本次保留) |

---

## 2. 目标与非目标

### 2.1 目标

- **G1**:`width:>2560`、`artist:周杰伦`、`duration:>300`、`pages:>50` 等元数据过滤**实际可用**(满足 `REQ-2.1-07` 全部 AC)。
- **G2**:索引构建后**后台渐进提取**媒体元数据,不阻塞首次扫描、不抢占搜索线程(满足 `REQ-2.1-06 AC5`,从 v3.1 提前)。
- **G3**:新文件经 FSEvents 入索引后**增量提取**单文件元数据。
- **G4**:提取结果**持久化**到 SQLite `metadata_json`,daemon 重启后从磁盘回填、不重复提取(满足 `REQ-2.1-06 AC3/AC4`)。
- **G5**:保持 v1.2 的**「零 I/O 过滤」**原则——查询时的元数据注入只读内存,不触发文件系统访问。

### 2.2 非目标

- ❌ 进度上报(`:stats` 显示提取进度,`REQ-2.1-06 AC6`)——仍延期。
- ❌ 改动 C 引擎(`CIndex` 不增加 metadata 字段;metadata 纯 Swift 侧承载)。
- ❌ GUI 元数据详情面板改造(继续用现有 `MetadataLoader`;本次只在搜索过滤路径接通)。
- ❌ 内容搜索(`content:`)、AI 语义、属性列化(属于其他对比项,不在本设计范围)。

---

## 3. 架构决策

### 3.1 选用:独立 `MetadataStore` actor(架构 A)

新建 `MetadataStore` actor,独占元数据的**内存映射 + 持久化 + 后台提取**。`SearchCoordinator` 在查询含元数据过滤时,从 `MetadataStore` 批量注入 metadata 到候选 `FileRecord`,再交给 `FilterPipeline`。

**为何不选「InMemoryIndex 内置旁路字典」(架构 B)**:`InMemoryIndex` 已是 C-backed actor,再塞 Swift 字典 + 异步提取职责会造成混合存储与职责膨胀;提取是异步并发操作,挂在 C 索引 actor 上不自然。独立 actor 满足单一职责、可独立 TDD、并发模型清晰,C 引擎保持纯粹。

### 3.2 注入策略:按需注入(仅当查询含元数据过滤)

`SearchCoordinator.search` 在 deduplicate 之后、`FilterPipeline.apply` 之前,**仅当 `filters` 含元数据过滤器时**,对候选集 id 批量查 `MetadataStore` 并重建带 metadata 的 `FileRecord`。无元数据过滤的查询**零注入开销**。

这一步只读 `MetadataStore` 的内存映射(O(1) per id),**不触发文件 I/O** → v1.2「零 I/O 过滤」原则得以保持。

---

## 4. 组件设计

### 4.1 `MetadataStore` actor(新建,`Sources/Media/MetadataStore.swift`)

```
职责:持有 id→metadata 内存映射,驱动后台提取,持久化到 SQLite
依赖:MetadataExtractorRegistry(提取)、IndexPersistence(持久化)、InMemoryIndex(只读 id/path/ext/mtime)
```

接口(草案,最终以 writing-plans 为准):

- `loadPersisted()` — 启动时从 SQLite `metadata_json` 批量加载到内存映射
- `extract(id:path:ext:mtime:)` — 提取单文件(FSEvents 增量 + 全量引擎复用)
- `extractAll(records:)` — 全量后台提取(扫完后触发):`TaskGroup` + 限流 + 可取消
- `metadata(for ids: [UInt32]) -> [UInt32: ExtractedMetadata]` — 批量内存查询(注入用)
- `flush()` — 把内存映射批量写回 SQLite `metadata_json`
- `cancelExtraction()` — 取消进行中的全量提取(索引重建 / SIGTERM)

**内部状态**:
- `cache: [UInt32: ExtractedMetadata]` — 内存映射
- `sourceMtime: [UInt32: TimeInterval]` — 每个 metadata 对应的文件 mtime(AC4 去重用)
- `attempted: Set<UInt32>` — 本提取周期内已尝试(含失败)的 id,避免同周期反复重试

### 4.2 提取触发挂载点(改动 `DaemonMain`)

- **全量**:首次扫描完成(`ScanEvent.scanComplete` 或现有 live 状态转换点)后,`DaemonMain` 调 `metadataStore.extractAll(records: index.mediaRecords())`,其中 `mediaRecords()` 返回扩展名 ∈ `MetadataExtractorRegistry.allSupportedExtensions` 的 `(id, path, ext, mtime)`。
- **增量**:FSEvents 新文件入索引的现有处理点,追加 `metadataStore.extract(id:path:ext:mtime:)`。
- **删除/移动**:FSEvents delete 事件在 `cindex_remove` 之后,同步 `metadataStore.remove(id)`(清内存映射 + SQLite 该 id 的 `metadata_json`),避免孤儿 metadata 与 id 复用错配。rename/move 的 id 行为见 R4,plan 验证后再定迁移策略。
- **关闭**:daemon SIGTERM 处理追加 `metadataStore.flush()`(与现有 SQLite flush + cursor 保存并列)。

### 4.3 注入挂载点(改动 `SearchCoordinator`)

`SearchCoordinator.search`(`SearchCoordinator.swift:82`)在 `deduplicate` 后:

```
if filters.containsMetadataFilter {
    let ids = deduplicated.map { $0.record.id }
    let meta = await metadataStore.metadata(for: ids)
    injected = deduplicated.map { $0.injecting(meta[$0.record.id]) }
    filtered = pipeline.apply(to: injected)
} else {
    filtered = pipeline.apply(to: deduplicated)
}
```

配套小改:
- `SearchFilter` 增 `var isMetadataFilter: Bool`(识别 metadataMin/Max/Range/Match 四个 case)
- `FileRecord` 增 `func withMetadata(_:) -> FileRecord`(`metadata` 是 `let`,需重建路径)
- `SearchResult` 增注入辅助(或 SearchCoordinator 直接重建)

### 4.4 `MetadataLoader` 关系

GUI 详情面板继续用 `MetadataLoader`(按需、per-path 缓存)。为避免 GUI 与搜索两条路径重复提取,`MetadataLoader` 优先查 `MetadataStore` 的内存映射,fallback 到自身提取。具体桥接在 writing-plans 细化(非本设计硬约束)。

---

## 5. 数据流

```
启动:    SQLite metadata_json ──loadPersisted()──▶ MetadataStore.cache
扫描完成: DaemonMain ──extractAll(mediaRecords)──▶ TaskGroup 提取 ──▶ cache + flush ──▶ SQLite
FSEvents: 新文件 ──extract(id)──▶ cache(+ 异步 flush)
查询:     SearchCoordinator ──(含元数据过滤?)──▶ metadataStore.metadata(for: ids) ──▶ 注入 FileRecord ──▶ FilterPipeline(零 I/O)
关闭:     SIGTERM ──flush()──▶ SQLite
```

---

## 6. 并发、限流与取消

- **并发度**:`TaskGroup` + 限流,默认并发 `min(8, CPU-2)`(plan 定最终值 + 常量)。提取任务 `Task(priority: .utility)`,不抢占搜索线程。
- **AC4 去重**:提取前比对 `sourceMtime[id]` 与当前文件 mtime,相同则跳过。文件改动才重提取。
- **失败处理**:extractor 返回 `nil` 的文件记入 `attempted`,**本提取周期内**不重试;下一周期(文件 mtime 变化或全量重扫)再试。损坏文件不崩溃(spec REQ-2.1-02~05 AC4)。
- **取消**:全量提取持有 task handle;索引重建 / daemon 退出时 `cancelExtraction()`。已提取的部分结果保留(不回滚)。
- **flush 策略**:全量提取每 N 条或周期性 flush(复用 `IndexPersistence` 批量写),避免内存堆积但不过度写盘。

---

## 7. 持久化

- 复用 `IndexPersistence.metadata_json`(JSON 编码 `ExtractedMetadata`),**不改 schema**(v2 列已存在)。
- 启动 `loadPersisted()`:批量读 `(id, metadata_json)` → 解码 → 内存映射。为避免启动时解码全部 FileRecord,plan 评估是否加一个「仅读 id+metadata_json」的轻量查询(优化项,非硬约束)。
- 写入复用 `IndexPersistence` 现有 upsert 路径(已 bind metadata_json)。

---

## 8. spec 影响(需求变更,走 `REQ_CHANGE_LOG`)

本次把原延期项提前,必须同步:

1. **`REQ_CHANGE_LOG.md`**:新增 `CHG-2026-06-19-01`,记录「REQ-2.1-06 AC5(后台批量提取)从 v3.1 提前到当前版本」,来源、影响范围、原因(过滤功能已发布却不可用,优先级高于延期标签)。
2. **`v2.1-media-metadata.md` REQ-2.1-06**:
   - AC5 状态从「延期至 v3.1」改为「本次实现」
   - 备注(commit 93d3e08)更新:异步批量提取已落地
3. **`REQ_STATUS.md`**:更新 REQ-2.1-06 统计(延期项数 -1)。
4. **`00-overview.md`**:若统计「延期项」总数,同步。
5. **`CLAUDE.md`**:版本路线表 v3.1「本地 RAG」描述中,元数据提取不再列为 v3.1 待办(若有提及)。

> 实现顺序:先改 spec(本设计批准后),再 TDD 实现,最后更新 REQ 内联状态图标。

---

## 9. 测试策略(TDD,先 failing)

| 层 | 测试 | 覆盖 |
|---|---|---|
| `MetadataStore` 单元 | `MetadataStoreTests` | 内存 CRUD、SQLite 往返(loadPersisted↔flush)、mtime 去重(AC4)、attempted 失败标记、批量查询 |
| 提取引擎 | `MetadataStoreExtractionTests` | 并发安全、限流不超额、cancelExtraction 中止、部分失败容错 |
| 注入 | `SearchCoordinatorMetadataTests` | 含元数据过滤→注入生效;不含→零注入;无元数据文件自动排除(REQ-2.1-07 AC5) |
| 集成 | `MetadataFilterIntegrationTests` | 全量提取后 `width:>2560` 命中;FSEvents 新文件提取后可过滤;持久化重启后仍可过滤 |
| 回归 | 现有 `FilterPipelineTests` / `SearchFilterTests` | 元数据过滤 AC 不退化 |

性能:`measure` 基准——含元数据过滤的查询注入开销(候选 1k,内存映射命中)< 设定阈值(plan 定)。

---

## 10. 风险与权衡

- **R1 首次提取耗时**:大库(数十万媒体文件)首次后台提取可能数分钟。缓解:渐进式 + 不阻塞搜索 + utility 优先级 + 持久化(仅首次付代价)。可接受(符合「speed is #1,但元数据过滤是增量能力」)。
- **R2 内存增长**:全库 metadata 进内存映射。按项目「memory is not a constraint」可接受;plan 评估估算(每条 metadata 字典约几百字节~1KB)。
- **R3 注入重构开销**:含元数据过滤时需重建候选 FileRecord。缓解:按需注入 + 候选通常已被文本搜索缩小。
- **R4 ID 一致性(关键)**:metadata 按 `UInt32 id` 索引,id 由 C 索引分配。须确保扫描→提取→注入→持久化全链路 id 一致,且**删除时同步清 metadata**(见 §4.2)。plan 须先验证 C 索引的 id 生命周期:`cindex_remove`(swap-with-last)是否导致 id 复用?rename/move 是否改变 id?SQLite id 与 C id 是否对齐?若 id 会复用,metadata 必须在 remove 时立即清除,且 extract 前用 path 校验,防止 A 文件的 metadata 挂到复用其 id 的 B 文件上。

---

## 11. 交叉引用

- **依赖的 REQ**:`specs/reqs/v2.1-media-metadata.md`(REQ-2.1-06、REQ-2.1-07)、`specs/reqs/v1.2-metadata-filter.md`(REQ-1.2-07 FilterExpression、「零 I/O」原则)
- **依赖的设计文档**:`specs/design/2026-05-26-deep-finder-design.md`(索引架构、daemon 数据流)
- **实现计划**:本设计批准后由 writing-plans 产出,路径待定(`specs/plans/` 或 `superpowers/plans/`)
- **相关代码**:`Sources/Media/`、`Sources/Search/{SearchCoordinator,FilterPipeline,SearchFilter}.swift`、`Sources/Index/{FileRecord,InMemoryIndex}.swift`、`Sources/Persist/{IndexPersistence,SchemaMigrator}.swift`、`Sources/Daemon/DaemonMain.swift`
