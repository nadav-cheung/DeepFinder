# DeepFinder — Search Enhancements 架构设计 (v1.1–v1.5)

> 本文档补齐 v1.1–v1.5 的**技术架构文档**覆盖（主设计文档 `2026-05-26-deep-finder-design.md` §3 仅覆盖 SearchProvider 协议与基础搜索流程，未展开高级语法/过滤/体验/内容搜索/重复查找）。对应 REQ 文件：
> - [`../reqs/v1.1-advanced-syntax.md`](../reqs/v1.1-advanced-syntax.md) — 高级搜索语法（7 REQ）
> - [`../reqs/v1.2-metadata-filter.md`](../reqs/v1.2-metadata-filter.md) — 元数据过滤（8 REQ）
> - [`../reqs/v1.3-search-exp.md`](../reqs/v1.3-search-exp.md) — 搜索体验（7 REQ）
> - [`../reqs/v1.4-content-search.md`](../reqs/v1.4-content-search.md) — 内容搜索（4 REQ）
> - [`../reqs/v1.5-duplicate.md`](../reqs/v1.5-duplicate.md) — 重复查找（6 REQ）
>
> 依赖：主设计文档 §2（索引引擎）、§3（SearchProvider/SearchCoordinator）。全部 v1.1–v1.5 REQ 已实现并测试。

---

## 1. 架构总览：统一查询流水线

v1.1–v1.5 的全部增强都接入**同一条查询流水线**，不破坏 v0.3 的 `SearchProvider` 协议：

```
用户输入 (query string + modifiers)
   │
   ▼
┌──────────────┐    ┌───────────────┐    ┌────────────────────┐
│ QueryParser  │───▶│ SearchQuery   │───▶│ SearchCoordinator  │  (actor)
│ (v1.1 AST)   │    │ + FilterExpr  │    │  ├ FileIndexProvider (in-memory)
└──────────────┘    │   (v1.2)      │    │  ├ ContentSearchProvider (v1.4)
                    └───────────────┘    │  └ DuplicateFinder (v1.5)
                                         └─────────┬──────────┘
                                                   │ AsyncSequence<SearchResult>
                            ┌──────────────────────┼──────────────────────┐
                            ▼                      ▼                      ▼
                     ┌─────────────┐       ┌───────────────┐       ┌──────────────┐
                     │ FilterPipe- │       │ SearchSorter  │       │ (content/dupe│
                     │ line (v1.2) │       │ (v1.3)        │       │  附带结果)    │
                     └─────────────┘       └───────────────┘       └──────────────┘
                                                   │
                                                   ▼
                                          CLI / GUI / IPC 输出
```

**设计原则**：
- **流水线分层**：解析（QueryParser）→ 过滤（FilterPipeline）→ 编排（SearchCoordinator）→ 排序（SearchSorter），每层独立可测。
- **协议扩展而非改写**：v1.4/v1.5 通过新增 `SearchProvider` 实现（ContentSearchProvider、DuplicateFinder）接入，不改 `SearchCoordinator` 主流程。
- **零外部依赖**：所有正则用 Swift `Regex`/ICU，哈希用 CryptoKit，无第三方库。

---

## 2. v1.1 — 高级搜索语法

**核心组件**：`QueryParser`（`QueryTerm.swift`）、`PatternMatcher`（`PatternMatcher.swift`）。

### 2.1 查询 AST

`QueryParser.parse(_:)` 将查询字符串解析为 `ParsedQuery`（含 `QueryAST`）：

```
QueryAST = term | wildcard | regex | and(ast,ast) | not(ast) | phrase("...")
```

- **布尔运算**：`|`(OR)、空格隐含 AND、`!`/`-`(NOT)、`<>` 分组、`""` 短语。
- **优先级**：NOT > AND > OR；分组 `<>` 提升优先级。
- **路径限定**：`/`（仅路径）、`parent:`、`path:`（`~` 自动展开，NFC 规范化）。
- **修饰符**：`case:`、`file:`、`folder:`、`ext:`——分**本地作用域**（仅当前项）与**全局作用域**（整条查询）。

### 2.2 模式匹配

`PatternMatcher` 处理需要非字面量匹配的叶子节点：
- **通配符** `*.pdf` / `prefix*`：编译为优化的前缀/后缀判断，避免回溯。
- **正则** `regex:\d{4}`：`Swift Regex`，编译结果缓存（`[String: Regex]`），避免重复编译开销。

**设计决策**：通配符不退化为正则——常见 `*.ext` 与 `prefix*` 走快速路径，仅复杂通配符才转 ICU。

---

## 3. v1.2 — 元数据过滤流水线

**核心组件**：`SearchFilter`（`SearchFilter.swift`）、`FilterPipeline`（`FilterPipeline.swift`）。

### 3.1 FilterExpression 模型

`SearchFilter` 是 `Codable` 值类型，表达单一谓词：

| 维度 | 语法示例 | 实现 |
|------|---------|------|
| 大小 | `size:>10mb`, `size:100kb..10mb` | 字节比较，单位解析（kb/mb/gb） |
| 日期 | `dm:today`, `dc:thisweek` | 相对日期窗口（修改/创建） |
| 扩展 | `ext:pdf;docx` | 集合成员 |
| 类型宏 | `audio:`/`video:`/`pic:`/`doc:` | `FileTypeGroup` 扩展名集合 |
| 类型 | `file:`/`folder:` | isDirectory |
| 深度 | `depth:3` | path 分隔符计数 |

`FilterPipeline` 持有 `[SearchFilter]`，`apply(_:)` 对 `SearchResult` 流逐项求值（短路 AND）。从 `SearchCoordinator.search()` 第 129–130 行接入。

### 3.2 与查询语法的集成

`QueryParser` 识别 `key:value` 形式的过滤前缀，将其从文本查询剥离，生成 `ParsedQuery.filterExpressions`——**过滤与文本匹配正交**，互不干扰。

---

## 4. v1.3 — 搜索体验

**核心组件**：`SearchSorter`、`BookmarkStore`（`SearchBookmark.swift`）、`AutocompleteProvider`。

### 4.1 多维排序

`SearchSorter` 支持 6 个排序键（`SortCriterion`）：name / size / date / extension / path / relevance（默认）。复合比较链；自然排序（`NaturalSort`）处理 `file2` < `file10`。`SearchCoordinator` 默认排序：**MatchType > name 长度 > 频率 > 日期 > 深度**（主设计文档 §3）。

### 4.2 书签与自定义过滤器

`BookmarkStore`（actor）持久化 `SearchBookmark`（查询 + 过滤表达式 + 时间戳）到 `~/.deep-finder/bookmarks.json`。自定义过滤器（`:filter save`）复用 `SearchFilter` 的 Codable 序列化。

### 4.3 自动补全

`AutocompleteProvider`（actor）为 REPL Tab 补全提供候选项：查询语法关键字、过滤前缀、已保存书签名、历史路径。通过 `CompletionEngine` + libedit `_completionEntryGenerator` 接入 readline。

---

## 5. v1.4 — 内容搜索

**核心组件**：`ContentScanner`（`ContentScanner.swift`）、`ContentSearchProvider`（`ContentSearchProvider.swift`）。

### 5.1 流式扫描

`ContentScanner` 以 **64 KB 块**流式读取（不整文件入内存），`TaskGroup` 并行扫描候选文件。每个匹配产生 `ContentMatch`（文件、行号、列、匹配文本）。

### 5.2 编码与边界

- **编码**：UTF-8 / UTF-16 LE/BE，BOM 自动探测；非文本扩展名跳过。
- **资源上限**：单文件 64 MB、总 I/O 512 MB、8 并发、1 万候选上限——防止内容搜索拖垮索引查询。
- **输出**：`ContentMatch` → 行:列 格式，CLI `TerminalFormatter` 高亮匹配。

`ContentSearchProvider` 实现 `SearchProvider` 协议（`AsyncSequence<SearchResult>`），`SearchCoordinator.cancel(queryID:)` 可取消长时间扫描。

---

## 6. v1.5 — 重复查找

**核心组件**：`DuplicateFinder`（`DuplicateFinder.swift`）、`FileHasher`（`FileHasher.swift`）。

### 6.1 分组策略

| 命令 | 分组键 | 复杂度 |
|------|--------|--------|
| `dupe:` | NFC + 小写名 | O(n) |
| `sizedupe:` | `FileRecord.size`（降序） | O(n) |
| `hashdupe:` | 两阶段 | 见下 |
| `empty:` | size==0 / 空目录 | O(n) |
| `len:` | 文件名 Unicode 标量数 | O(n) |

### 6.2 两阶段内容哈希（hashdupe）

1. **粗筛**：按 `size` 分组——只有同 size 才可能内容相同（零 I/O）。
2. **精确认证**：对每个 size 组用 `FileHasher`（CryptoKit SHA-256）计算哈希；**前缀哈希优化**——先哈希前 4 KB，仅前缀冲突才哈希全文件，大幅减少全文件 I/O。

`DuplicateGroup`（`Codable`）经 IPC 返回，CLI/GUI 可折叠展示。

---

## 7. REQ ↔ 实现 ↔ 测试 可追溯性

| 版本 | REQ 文件 | 主要实现文件 | 测试文件 |
|------|---------|-------------|---------|
| v1.1 | v1.1-advanced-syntax.md | `QueryTerm.swift`, `PatternMatcher.swift`, `SearchTypes.swift` | `QueryParserTests`, `PatternMatcherTests`, `SearchTypesTests` |
| v1.2 | v1.2-metadata-filter.md | `SearchFilter.swift`, `FilterPipeline.swift`, `SearchCoordinator.swift` | `SearchFilterTests`, `FilterPipelineTests`, `SearchCoordinatorTests` |
| v1.3 | v1.3-search-exp.md | `SearchSorter.swift`, `SearchBookmark.swift`, `AutocompleteProvider.swift` | `SearchSorterTests`, `NaturalSortTests`, `SearchBookmarkTests`, `AutocompleteTests` |
| v1.4 | v1.4-content-search.md | `ContentScanner.swift`, `ContentSearchProvider.swift` | `ContentSearchTests` |
| v1.5 | v1.5-duplicate.md | `DuplicateFinder.swift`, `FileHasher.swift` | `DuplicateFinderTests` |

> 完整逐 REQ 状态见 [`../reqs/REQ_STATUS.md`](../reqs/REQ_STATUS.md)。相关架构决策见 `docs/adr/`：ADR-005（NFC 规范化）、ADR-011（actor 并发）、ADR-013（混合索引结构）。

---

## 8. 已知限制与后续

- 内容搜索 `ContentSearchProvider.cancel` 为 no-op（同步扫描，文件内即完成）——已在主设计文档并发集群中标注为低影响延期项。
- 重复查找的 `hashdupe` 全文件哈希在大规模同 size 组下仍较慢；前缀哈希优化已缓解，进一步优化（采样哈希）为未来增强。
