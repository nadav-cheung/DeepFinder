# Everything Search — 需求管理

需求 ID 格式：`REQ-{版本}-{序号}`，如 `REQ-1.0-01`。
优先级：P0 必须 / P1 重要 / P2 增强 / P3 未来。
状态：📋 规划中 / 🔨 开发中 / ✅ 已完成 / ❌ 已取消。
执行方式：🖥️ 本地 / ☁️ 云端 / 🖥️☁️ 混合（本地为主，云端辅助）。

详细架构设计见 `2026-05-26-everything-search-design.md`。

---

## v0.1 — 索引核心

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-0.1-01 | FileRecord 数据模型 | P0 | ✅ | 🖥️ | 核心数据结构：id, name, originalName, path, parentPath, isDirectory, size, createdAt, modifiedAt, extension。Codable + Sendable |
| REQ-0.1-02 | Trie 前缀索引 | P0 | 📋 | 🖥️ | Unicode scalar 字典树，O(k) 前缀匹配，支持即时补全 |
| REQ-0.1-03 | FullSubstringMap | P0 | 📋 | 🖥️ | 文件名 ≤64 字符的全子串 → FileRecord.ID 映射，O(1) 查询。速度换内存 |
| REQ-0.1-04 | TrigramIndex | P0 | 📋 | 🖥️ | 文件名 >64 字符的 trigram → posting list，交集 + 验证 |
| REQ-0.1-05 | PinyinIndex | P0 | 📋 | 🖥️ | CFStringTokenizer → 拼音 token → Trie。支持全拼和首字母缩写 |
| REQ-0.1-06 | InMemoryIndex (actor) | P0 | 📋 | 🖥️ | 组合 Trie + FullSubstringMap + TrigramIndex + PinyinIndex。actor 隔离，快照读 API |
| REQ-0.1-07 | 测试固件 | P0 | 📋 | 🖥️ | FileRecordGenerator, EdgeCaseFixtures, PerformanceFixtures |

## v0.2 — 文件系统

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-0.2-01 | FileSystemEventStream 协议 | P0 | 📋 | 🖥️ | 抽象层：start/stop/isRunning。生产用 FSEventStreamCreate，测试用 MockEventStream |
| REQ-0.2-02 | FileScanner 全量扫描 | P0 | 📋 | 🖥️ | FileManager.enumerator 遍历所有卷，TaskGroup 按卷并行，边扫边建索引 |
| REQ-0.2-03 | FSEventWatcher | P0 | 📋 | 🖥️ | 文件创建/删除/重命名/修改 → 增量更新索引。启动衔接：stale → FSEvents → 验证 → live |
| REQ-0.2-04 | IndexPersistence | P0 | 📋 | 🖥️ | SQLite WAL 持久化 FileRecord[]，权限 600，批量写入（5s 或 100 条） |
| REQ-0.2-05 | 索引恢复 | P1 | 📋 | 🖥️ | 加载时校验（行数 + checksum），失败删除重建 + 进度 UI |

## v0.3 — 搜索

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-0.3-01 | SearchProvider 协议 | P0 | 📋 | 🖥️ | AsyncSequence<SearchResult, Never>，cancel(queryID:)，prepare() |
| REQ-0.3-02 | SearchQuery / SearchResult | P0 | 📋 | 🖥️ | SearchQuery: NFC + lowercased。SearchResult: record + score + matchType。MatchType: exact/prefix/substring/pinyin |
| REQ-0.3-03 | SearchCoordinator (@MainActor) | P0 | 📋 | 🖥️ | 分发查询 → 消费 AsyncSequence → 合并排序 → 渲染。内存查询无防抖 |
| REQ-0.3-04 | 排序策略 | P1 | 📋 | 🖥️ | MatchType 权重 > 文件名长度 > 使用频率 > 修改时间 > 路径深度 |
| REQ-0.3-05 | 性能基准测试 | P0 | 📋 | 🖥️ | XCTMetric + measure，100k/1M 文件，p99 延迟目标见 spec §8 |

## v0.4 — UI

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-0.4-01 | SearchPanelView (NSPanel) | P0 | 📋 | 🖥️ | Liquid Glass 材质，屏幕顶部居中，点击外部/Esc 关闭 |
| REQ-0.4-02 | SearchBarView | P0 | 📋 | 🖥️ | 图标 + TextField + 清除按钮，.glassEffect() Liquid Glass |
| REQ-0.4-03 | ResultsListView | P0 | 📋 | 🖥️ | LazyVStack 虚拟化，分页 100 条，"还有 N 个结果" 按钮 |
| REQ-0.4-04 | ResultRowView | P0 | 📋 | 🖥️ | 文件图标 + 文件名（高亮匹配）+ 路径 + 大小/日期 |
| REQ-0.4-05 | IntelligenceGlow | P1 | 📋 | 🖥️ | AngularGradient 4 层旋转光晕，~1.8s 周期，reduceMotion 降级 |
| REQ-0.4-06 | FileIconCache | P1 | 📋 | 🖥️ | NSCache 按扩展名缓存 16x16 图标 |

## v0.5 — 集成

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-0.5-01 | GlobalHotkey (⌥Space) | P0 | 📋 | 🖥️ | RegisterEventHotKey 优先，CGEventTap fallback。冲突检测 + 首次授权引导 |
| REQ-0.5-02 | StatusBarController | P0 | 📋 | 🖥️ | 菜单栏图标，点击唤起搜索面板 |
| REQ-0.5-03 | AppDelegate + 启动流程 | P0 | 📋 | 🖥️ | 加载索引 → FSEvents → 验证 → 注册热键 → 就绪 |
| REQ-0.5-04 | SettingsView | P1 | 📋 | 🖥️ | 索引排除路径、热键配置、开机自启 |

---

## v1.0 — 核心搜索（首个发布版本）

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-1.0-01 | Quick Look 预览 | P1 | 📋 | 🖥️ | Space 键快速预览选中文件 |
| REQ-1.0-02 | 右键菜单 | P1 | 📋 | 🖥️ | 在 Finder 中显示 / 复制路径 / 拖拽 / 打开方式 |
| REQ-1.0-03 | 拖拽支持 | P2 | 📋 | 🖥️ | 拖拽文件到其他应用 |
| REQ-1.0-04 | UI 测试 | P1 | 📋 | 🖥️ | SearchPanelUITests |
| REQ-1.0-05 | 模糊纠错 | P1 | 📋 | 🖥️ | 编辑距离算法 + Trie 模糊匹配，输入 "repotr" → 建议 "report" |
| REQ-1.0-06 | 高亮匹配 | P1 | 📋 | 🖥️ | 结果列表高亮匹配子串，保留原始大小写 |

## v1.1 — 高级搜索语法

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-1.1-01 | 布尔运算符 | P0 | 📋 | 🖥️ | 空格=AND, \|=OR, !=NOT。支持分组 `< >` |
| REQ-1.1-02 | 通配符 | P0 | 📋 | 🖥️ | `*` 任意字符, `?` 单字符 |
| REQ-1.1-03 | 正则表达式 | P1 | 📋 | 🖥️ | `regex:` 前缀激活正则模式 |
| REQ-1.1-04 | 路径限定 | P1 | 📋 | 🖥️ | `Documents\ report`, `parent:~/Documents` |
| REQ-1.1-05 | 搜索修饰符 | P1 | 📋 | 🖥️ | `case:`, `file:`, `folder:`, `ext:`, `path:`, `wfn:` |
| REQ-1.1-06 | 搜索历史 | P1 | 📋 | 🖥️ | ↑↓ 回溯历史查询，持久化最近 100 条 |
| REQ-1.1-07 | 搜索语法解析器 | P0 | 📋 | 🖥️ | 解析搜索语法为 AST → 传给 SearchProvider 执行 |

## v1.2 — 元数据过滤

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-1.2-01 | 大小过滤 | P0 | 📋 | 🖥️ | `size:>1mb`, `size:100kb..10mb`，支持 kb/mb/gb |
| REQ-1.2-02 | 日期过滤 | P0 | 📋 | 🖥️ | `dm:today`, `dc:thisweek`, 范围 `dm:2026-01-01..03-31` |
| REQ-1.2-03 | 扩展名过滤 | P0 | 📋 | 🖥️ | `ext:pdf;doc;xlsx`，分号多扩展名 |
| REQ-1.2-04 | 类型过滤宏 | P1 | 📋 | 🖥️ | `audio:`, `video:`, `pic:`, `doc:` 预定义文件类型 |
| REQ-1.2-05 | 文件/文件夹限定 | P1 | 📋 | 🖥️ | `file:`, `folder:` |
| REQ-1.2-06 | 路径深度 | P2 | 📋 | 🖥️ | `depth:3` |
| REQ-1.2-07 | 高级搜索面板 | P1 | 📋 | 🖥️ | GUI 表单构建复杂查询，对标 Everything Advanced Search |
| REQ-1.2-08 | 元数据索引扩展 | P0 | 📋 | 🖥️ | InMemoryIndex 增加按 size/date/ext 的排序索引 |

## v1.3 — 搜索体验

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-1.3-01 | 书签 | P1 | 📋 | 🖥️ | 保存搜索+排序+过滤，一键恢复 |
| REQ-1.3-02 | 自定义过滤器 | P1 | 📋 | 🖥️ | 预定义搜索条件 + 快捷键 + 宏，如 `photos:` → `ext:jpg;png;heic pic:` |
| REQ-1.3-03 | 结果排序 | P0 | 📋 | 🖥️ | 名称/大小/日期/扩展名/路径，自然排序（natural sort）|
| REQ-1.3-04 | 排序持久化 | P2 | 📋 | 🖥️ | 记住上次排序方式 |
| REQ-1.3-05 | 上下文搜索 | P1 | 📋 | 🖥️ | 监听 frontmost app，在 Xcode 中搜索自动聚焦 `.swift` 文件 |
| REQ-1.3-06 | 预测推荐 | P1 | 📋 | 🖥️ | 统计使用频率+时间模式，周一推荐周一常用的文件 |
| REQ-1.3-07 | 搜索建议 | P2 | 📋 | 🖥️ | 基于历史和热门文件的自动补全下拉 |

## v1.4 — 内容搜索

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-1.4-01 | content: 函数 | P0 | 📋 | 🖥️ | `content:keyword` 实时扫描文件内容，结合其他过滤先缩小范围 |
| REQ-1.4-02 | 编码支持 | P0 | 📋 | 🖥️ | UTF-8, UTF-16, UTF-16BE 自动检测 |
| REQ-1.4-03 | 文件类型限定 | P1 | 📋 | 🖥️ | `ext:swift;py;md content:TODO` 只搜索特定扩展名 |
| REQ-1.4-04 | 行号定位 | P2 | 📋 | 🖥️ | 显示匹配行号，点击跳转编辑器（仅文本文件） |

## v1.5 — 重复文件与高级查找

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-1.5-01 | 按名称查重 | P1 | 📋 | 🖥️ | `dupe:` 相同文件名 |
| REQ-1.5-02 | 按大小查重 | P1 | 📋 | 🖥️ | `sizedupe:` 相同大小 |
| REQ-1.5-03 | 按内容哈希查重 | P1 | 📋 | 🖥️ | `hashdupe:` SHA-256，比 Everything 更精确 |
| REQ-1.5-04 | 空文件夹 | P2 | 📋 | 🖥️ | `empty:` 查找空目录 |
| REQ-1.5-05 | 文件名长度 | P2 | 📋 | 🖥️ | `len:>100` |
| REQ-1.5-06 | 子项计数 | P2 | 📋 | 🖥️ | `childcount:0`, `childfilecount:>10` |

## v2.0 — 扩展索引

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-2.0-01 | 外置卷索引 | P1 | 📋 | 🖥️ | USB/Thunderbolt 自动索引，卸载保留，重新挂载增量更新 |
| REQ-2.0-02 | 网络卷索引 | P2 | 📋 | 🖥️ | SMB/AFP/NFS 共享目录索引 |
| REQ-2.0-03 | 离线文件列表 | P2 | 📋 | 🖥️ | 对标 File Lists — 光盘/归档媒体的离线索引 |
| REQ-2.0-04 | Spotlight 元数据集成 | P1 | 📋 | 🖥️ | mdls 提取尺寸、时长、标签等元数据 |
| REQ-2.0-05 | 索引日志 | P2 | 📋 | 🖥️ | 记录文件变更历史，对标 Index Journal |
| REQ-2.0-06 | 排除规则 | P1 | 📋 | 🖥️ | 可配置的排除/包含路径和 glob 模式 |
| REQ-2.0-07 | 项目识别 | P1 | 📋 | 🖥️ | 检测 .git/.xcodeproj/package.json，自动识别项目边界，项目内聚合搜索 |
| REQ-2.0-08 | 自动标签 | P1 | 📋 | 🖥️☁️ | 云端 LLM 基于文件名/路径推断标签，本地 CoreML 分类兜底 |
| REQ-2.0-09 | 代码理解 | P2 | 📋 | 🖥️ | AST 解析代码文件，索引函数名/类名/变量名 |
| REQ-2.0-10 | 智能清理建议 | P2 | 📋 | 🖥️ | "Downloads 有 200 个文件 30 天未动" — 本地统计分析 |

## v2.1 — 媒体元数据

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-2.1-01 | 图片尺寸搜索 | P1 | 📋 | 🖥️ | `width:>2560`, `dimensions:800x600..1920x1080`，EXIF |
| REQ-2.1-02 | 图片方向 | P2 | 📋 | 🖥️ | `orientation:landscape` |
| REQ-2.1-03 | 音频标签搜索 | P1 | 📋 | 🖥️ | `artist:周杰伦`, `album:范特西`, `genre:pop` |
| REQ-2.1-04 | 视频信息搜索 | P2 | 📋 | 🖥️ | `duration:>300`, `codec:h264` |
| REQ-2.1-05 | PDF 元数据搜索 | P2 | 📋 | 🖥️ | `pdf-author:xxx`, `pdf-pages:>50` |
| REQ-2.1-06 | AI 摘要气泡 | P1 | 📋 | 🖥️☁️ | 悬停文件显示 AI 生成的一句话摘要，首次生成后缓存本地 |
| REQ-2.1-07 | 内容摘要索引 | P1 | 📋 | 🖥️ | 首次索引文件时本地 CoreML 生成摘要，存入 SQLite 供搜索匹配 |

## v2.2 — 服务与集成

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-2.2-01 | HTTP 搜索服务 | P2 | 📋 | 🖥️ | 本地 Web 界面，浏览器搜索文件 |
| REQ-2.2-02 | 命令行工具 | P1 | 📋 | 🖥️ | `es search "keyword"` — 终端搜索，输出 JSON/纯文本 |
| REQ-2.2-03 | URL Scheme | P1 | 📋 | 🖥️ | `everything://search?q=keyword` — 其他 app 调起 |
| REQ-2.2-04 | Shortcuts 集成 | P2 | 📋 | 🖥️ | Apple Shortcuts 动作 |
| REQ-2.2-05 | AppleScript | P2 | 📋 | 🖥️ | 脚本化搜索和结果获取 |
| REQ-2.2-06 | Share Extension | P3 | 📋 | 🖥️ | 从其他 app 搜索文件 |

## v3.0 — AI 辅助搜索

**核心约束：全部文件不离开本地。只有元数据和用户查询文本可以发送到云端。**

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-3.0-01 | AIModelProvider 协议 | P0 | 📋 | 🖥️ | AI 模型统一接口：complete(), translateToSearchSyntax()。详见 spec §v3.0 |
| REQ-3.0-02 | Privacy Boundary | P0 | 📋 | 🖥️ | 隐私边界：FileMetadataSummary 只含 name/path/size/date/ext/localTags。路径默认脱敏 |
| REQ-3.0-03 | DeepSeek 接入 | P1 | 📋 | ☁️ | DeepSeek API 实现 AIModelProvider |
| REQ-3.0-04 | 千问接入 | P1 | 📋 | ☁️ | Qwen API 实现 AIModelProvider |
| REQ-3.0-05 | 自然语言搜索 | P0 | 📋 | 🖥️☁️ | "找上周改过的大文件" → LLM 翻译 → `dm:lastweek size:>10mb` |
| REQ-3.0-06 | 结果摘要 | P1 | 📋 | 🖥️☁️ | 基于元数据生成搜索结果摘要和分类 |
| REQ-3.0-07 | 搜索建议气泡 | P1 | 📋 | 🖥️☁️ | UI 层 AI 建议气泡，异步请求，不阻塞主搜索 |
| REQ-3.0-08 | 语义分组 | P1 | 📋 | 🖥️☁️ | 大量结果自动分组：设计稿/合同/报告/代码/其他 |
| REQ-3.0-09 | 匹配解释 | P2 | 📋 | 🖥️ | 搜索结果旁显示 "匹配原因：文件名含 report，上周修改" |
| REQ-3.0-10 | LocalVisionProvider | P1 | 📋 | 🖥️ | Vision + CoreML 本地图片分析 → 生成标签 → 存入索引。零外传 |
| REQ-3.0-11 | 以图搜图 | P1 | 📋 | 🖥️ | 本地图片特征提取 + 向量索引，截图/拖图搜索相似文件。零外传 |
| REQ-3.0-12 | LocalSpeechProvider | P2 | 📋 | 🖥️ | Speech 框架本地语音识别，文本送云端理解意图 |
| REQ-3.0-13 | 跨语言搜索 | P1 | 📋 | 🖥️☁️ | 中文搜 "设计稿" 也能命中 "mockup_v2.fig" |
| REQ-3.0-14 | 自然语言操作 | P2 | 📋 | 🖥️☁️ | "把 Downloads 里的截图移到相册" → LLM 生成操作指令 → 用户确认 → 本地执行 |
| REQ-3.0-15 | 用户隐私控制面板 | P0 | 📋 | 🖥️ | Settings > AI：模型选择/元数据发送开关/路径脱敏/API Key/数据预览 |
| REQ-3.0-16 | 剪贴板搜索 | P2 | 📋 | 🖥️ | 复制文字 → 自动搜索本地包含相似内容的文件 |

## v3.1 — 本地 RAG（检索增强生成）

**全部本地执行，零外传。**

| ID | 需求 | 优先级 | 状态 | 执行 | 说明 |
|----|------|--------|------|------|------|
| REQ-3.1-01 | 文件内容分块 | P0 | 📋 | 🖥️ | 512 tokens/chunk，overlap 64。支持 txt/md/pdf/docx/代码文件 |
| REQ-3.1-02 | 本地 Embedding 引擎 | P0 | 📋 | 🖥️ | all-MiniLM-L6-v2 CoreML 量化版，~30MB，M4 GPU ~1ms/chunk |
| REQ-3.1-03 | 向量索引存储 | P0 | 📋 | 🖥️ | SQLite vec 扩展或 hnswlib，向量 + chunk 元数据 |
| REQ-3.1-04 | 增量 Embedding 更新 | P1 | 📋 | 🖥️ | FSEvents → 只重新 embedding 变更文件 |
| REQ-3.1-05 | 语义检索 | P0 | 📋 | 🖥️ | 查询 → embedding → cosine similarity Top-K → 返回最相关 chunk |
| REQ-3.1-06 | 本地小模型生成 | P1 | 📋 | 🖥️ | Llama 3.2 1B/3B CoreML 量化版，M4+ 24GB 可流畅运行 |
| REQ-3.1-07 | RAG 问答 | P1 | 📋 | 🖥️ | 用户问 "去年收入增长多少" → 检索相关 chunk → 本地 LLM 回答 + 引用文件路径 |

## macOS 特有增强

| ID | 需求 | 优先级 | 状态 | 执行 | 版本 | 说明 |
|----|------|--------|------|------|------|------|
| REQ-MAC-01 | Finder 标签搜索 | P1 | 📋 | 🖥️ | v2.0 | 搜索 macOS Finder Tags（红/橙/黄/绿/蓝/紫/灰）|
| REQ-MAC-02 | Finder 评论搜索 | P2 | 📋 | 🖥️ | v2.0 | 搜索 Spotlight Comments |
| REQ-MAC-03 | iCloud 同步状态 | P2 | 📋 | 🖥️ | v2.0 | 区分本地/云端/仅云端文件 |
| REQ-MAC-04 | APFS 快照搜索 | P2 | 📋 | 🖥️ | v2.0 | Time Machine 快照中搜索历史版本 |
| REQ-MAC-05 | 桌面 Widgets | P3 | 📋 | 🖥️ | v2.2 | 桌面/通知中心小组件显示搜索/最近文件 |
| REQ-MAC-06 | Live Activity | P3 | 📋 | 🖥️ | v2.2 | 索引进度 Live Activity（锁屏/通知中心）|

---

## 需求统计

| 版本 | P0 | P1 | P2 | P3 | 合计 |
|------|----|----|----|----|------|
| v0.1 | 7 | 0 | 0 | 0 | 7 |
| v0.2 | 4 | 1 | 0 | 0 | 5 |
| v0.3 | 4 | 1 | 0 | 0 | 5 |
| v0.4 | 4 | 2 | 0 | 0 | 6 |
| v0.5 | 3 | 1 | 0 | 0 | 4 |
| v1.0 | 0 | 4 | 2 | 0 | 6 |
| v1.1 | 2 | 4 | 0 | 0 | 6 |
| v1.2 | 3 | 3 | 1 | 0 | 7 |
| v1.3 | 1 | 4 | 2 | 0 | 7 |
| v1.4 | 2 | 1 | 1 | 0 | 4 |
| v1.5 | 0 | 3 | 3 | 0 | 6 |
| v2.0 | 0 | 4 | 5 | 0 | 9 |
| v2.1 | 0 | 3 | 4 | 0 | 7 |
| v2.2 | 0 | 2 | 3 | 1 | 6 |
| v3.0 | 4 | 8 | 3 | 0 | 15 |
| v3.1 | 3 | 3 | 0 | 0 | 6 |
| MAC | 0 | 1 | 3 | 2 | 6 |
| **合计** | **33** | **44** | **27** | **3** | **107** |

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-05-29 | v1.0 | 初始需求列表，基于 Everything 全功能调研 + AI 辅助设计 + RAG 方案，共 107 项需求 |
