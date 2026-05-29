# DeepFinder — 需求管理

需求 ID 格式：`REQ-{版本}-{序号}`，如 `REQ-1.0-01`。
优先级：P0 必须 / P1 重要 / P2 增强 / P3 未来。
状态：📋 规划中 / 🔨 开发中 / ✅ 已完成 / ❌ 已取消。
执行方式：🖥️ 本地 / ☁️ 云端 / 🖥️☁️ 混合。

详细架构设计见 `2026-05-26-deep-finder-design.md`。

---

## v0.1 — 索引核心

### REQ-0.1-01 FileRecord 数据模型 ✅ 🖥️ P0

**用户场景**：所有搜索功能的基础——用户不会直接感知 FileRecord，但它的设计决定了搜索速度和结果准确性。

**验收标准**：
- [x] FileRecord 包含：id(UInt32), name(NFC), originalName, path, parentPath, isDirectory, size, createdAt, modifiedAt, extension(String?)
- [ ] FileRecord 前向兼容字段：isHidden(Bool), isSymlink(Bool), contentType(String?) — 扫描时从 FileManager 属性获取，为后续版本功能预留
- [x] Codable + Sendable，Swift 6 严格并发安全
- [x] JSON 编解码往返零丢失
- [x] 5 个单元测试通过

---

### REQ-0.1-02 Trie 前缀索引 📋 🖥️ P0

**用户场景**：用户输入 "rep" → 即时看到 "report.pdf", "reports/", "repository/" 前缀匹配结果。每个按键都有即时反馈。

**操作流程**：
1. 用户键入 "r" → 显示所有以 r 开头的文件
2. 继续键入 "rep" → 缩小到 "rep" 前缀
3. 继续键入 "repo" → 进一步缩小

**验收标准**：
- [ ] Unicode scalar 粒度，支持中文/日文/emoji 文件名
- [ ] 插入 100 万条记录 < 3s
- [ ] 前缀查询 p99 < 2ms（100 万记录）
- [ ] 支持中文文件名前缀匹配（"季" → "季度报告.pdf"）
- [ ] 边界：空字符串返回空，超长前缀返回空或精确匹配

---

### REQ-0.1-03 FullSubstringMap 📋 🖥️ P0

**用户场景**：用户输入 "port" → 瞬间看到 "report.pdf", "passport.jpg", "airport_map.png"——任何包含 "port" 的文件，不限位置。这是对标 Everything 的核心体验：**打字即出结果，零延迟**。

**操作流程**：
1. 用户输入任意子串（不限前缀）
2. 立即看到所有包含该子串的文件
3. 结果按相关性排序

**验收标准**：
- [ ] 文件名 ≤64 字符：所有子串预建映射，查询 O(1)
- [ ] 查询 p99 < 1ms（100 万记录，1 万次随机查询）
- [ ] 大小写不敏感（存储 lowercased，查询 lowercased）
- [ ] 返回结果包含精确文件名（originalName 保留原始大小写）
- [ ] 边界：重复子串不重复返回（"aaa" 在 "baaab" 中多个位置，但文件只返回一次）
- [ ] 边界：空字符串返回空结果

---

### REQ-0.1-04 TrigramIndex 📋 🖥️ P0

**用户场景**：极少数超长文件名（>64 字符）的兜底匹配。用户不应感知到阈值差异——搜索体验和短文件名一致。

**验收标准**：
- [ ] 文件名 >64 字符：trigram → posting list，交集 + 精确验证
- [ ] 查询结果与 FullSubstringMap 的语义一致（用户无感知差异）
- [ ] 与 FullSubstringMap 协同：同一查询同时覆盖两类文件名

---

### REQ-0.1-05 PinyinIndex 📋 🖥️ P0

**用户场景**：中文用户的强需求——用户输入 "baogao" 或 "bg" → 看到所有中文文件名含 "报告" 的文件。中文用户可以用拼音快速找到中文文件名。

**操作流程**：
1. 用户输入 "baogao" → 全拼匹配 → "季度报告.pdf", "年度报告.docx"
2. 用户输入 "bg" → 首字母缩写匹配 → 同样的结果
3. 混合输入 "jdbg" → "季度报告.pdf"（首字母逐字匹配）

**验收标准**：
- [ ] CFStringTokenizer 提取拼音 token → 独立 Trie
- [ ] 支持全拼（"baogao"）和首字母缩写（"bg"）
- [ ] 中文/英文混合文件名正确处理（"Q3报告.pdf" → "Q3baogao"）
- [ ] 拼音查询 p99 < 15ms（100 万记录）
- [ ] 边界：纯英文文件名不产生拼音 token（避免误匹配）
- [ ] 使用 CFLocaleWithIdentifier("zh-Hans") 作为默认 locale
- [ ] 声调标记不存储（用户输入不含声调）
- [ ] 拼音索引同时构建两个 Trie：(1) 全拼 Trie（存储完整拼音 token）(2) 首字母 Trie（取每个拼音 token 首字母拼接）
- [ ] 繁体中文字符名通过 CFStringTransform(kCFStringTransformMandarinLatin) 转换

---

### REQ-0.1-06 InMemoryIndex (actor) 📋 🖥️ P0

**用户场景**：用户无感知，但这是所有搜索功能的入口。用户只需知道：搜索即时出结果，索引在后台实时更新。

**验收标准**：
- [ ] 组合 Trie + FullSubstringMap + TrigramIndex + PinyinIndex
- [ ] actor 隔离：所有读写通过 actor isolation
- [ ] 快照读 API：`snapshot() -> IndexSnapshot`（不可变，供 SearchCoordinator 安全消费）
- [ ] 插入/删除操作不影响正在进行的查询（快照隔离）
- [ ] 100 万 FileRecord 索引构建 < 10s
- [ ] 内存 < 10GB（100 万记录，平均 20 字符文件名；超过上限时对长文件名降级为 TrigramIndex）
- [ ] Actor 队列深度上限 10,000 pending mutations，溢出时丢弃最旧的 pending mutations 并记录 warning log（含丢弃数量和队列深度）
- [ ] 提供 batch mutation API（insertBatch/deleteBatch）减少单次 mutation 开销，批量操作在单次 actor hop 内完成

---

### REQ-0.1-07 测试固件 📋 🖥️ P0

**用户场景**：无直接用户感知，但保证质量。用户最终受益于可靠的搜索结果。

**验收标准**：
- [ ] FileRecordGenerator：可配置数量的随机 FileRecord 生成器
- [ ] EdgeCaseFixtures：空文件名、超长文件名、emoji、NFD/NFC 混合、特殊字符
- [ ] PerformanceFixtures：10k / 100k / 1M 规模的测试数据集

---

## v0.2 — 文件系统

### REQ-0.2-01 FileSystemEventStream 协议 📋 🖥️ P0

**用户场景**：用户创建/删除/重命名文件后，搜索结果立即反映变化——不需要手动刷新或等待。

**验收标准**：
- [ ] 协议：start(paths:handler:), stop(), isRunning
- [ ] 生产实现 FSEventStreamImpl：包装 FSEventStreamCreate
- [ ] 测试实现 MockEventStream：可编程注入事件
- [ ] 事件类型：创建、删除、重命名、修改
- [ ] 延迟目标：文件变更后 ≤2s 反映在搜索结果中

---

### REQ-0.2-02 FileScanner 全量扫描 📋 🖥️ P0

**用户场景**：首次启动或索引损坏后，扫描全部文件。用户看到进度条，但扫描过程中已可搜索（边扫边建索引）。用户不想等扫描完成才能开始用。

**操作流程**：
1. 首次启动 → daemon 日志输出 "正在索引... 已扫描 12,345 / ~500,000 文件"
2. 扫描过程中 CLI 查询 → 已扫描的文件立即可搜索
3. 扫描完成 → 索引状态变为 live

**验收标准**：
- [ ] FileManager.enumerator 遍历所有卷
- [ ] TaskGroup 按卷并行扫描（外置卷并行不阻塞主卷）
- [ ] 边扫边建索引：扫描 N 条后立即可搜索
- [ ] 跳过：/System, /Library, .Trash, .git, node_modules, .Spotlight-V100（可配置）
- [ ] 隐私排除：~/Library/Caches, ~/Library/Cookies, ~/Library/Keychains
- [ ] 只索引当前用户 home + 系统共享目录
- [ ] 50 万文件扫描 < 30s（M4 内置 SSD）。外置卷/网络卷扫描时间取决于卷 I/O 速度，按比例延长；外置卷低优先级后台扫描，daemon 日志记录各卷独立进度

**错误处理验收标准**：
- [ ] Permission denied：捕获 FileManager.enumerator 的 `Swift.EncodingError` / POSIX EACCES，跳过该目录，计数 +1，继续扫描其他目录
- [ ] 跳过的受限目录计数汇总：扫描完成后 daemon 日志记录 "跳过 N 个受限目录"（N>0 时记录，含路径列表）。CLI `:stats` 命令可查询受限目录计数
- [ ] Full Disk Access 未授予或部分授予：启动时检测受限目录数量，若受限目录 ≥3（~/Documents, ~/Desktop, ~/Downloads 等），daemon 日志输出警告 "部分目录因权限限制无法索引"，IPC index_status 请求返回权限状态信息。v2.0 GUI 可展示提示和 "打开系统设置" 按钮（跳转 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）
- [ ] 错误日志策略：所有跳过/失败的目录路径和原因写入 `~/.deep-finder/log/scan-YYYY-MM-DD.log`，格式 `[HH:mm:ss] [WARN] SKIP: {path} — {reason}`，日志文件保留最近 7 天自动轮转

---

### REQ-0.2-03 FSEventWatcher 📋 🖥️ P0

**用户场景**：后台持续运行，用户无感知。当用户在 Finder 中新建文件后切回 DeepFinder，新文件已在结果中。

**验收标准**：
- [ ] 文件创建 → 插入索引；删除 → 移除；重命名 → 删除旧+插入新；修改 → 更新元数据
- [ ] 启动衔接：加载持久化索引 → stale → 启动 FSEvents → 补齐 cursor 差距 → verifying → live
- [ ] cursor 失效时触发全量重建（不阻塞搜索线程）
- [ ] 索引状态机通过 IPC 暴露：stale="结果可能不完整" / verifying="验证中..." / live=无提示 / error="索引可能不完整，实时监控已停止"。CLI `:stats` 命令显示状态

**错误处理验收标准**：
- [ ] FSEventStream 启动失败（`FSEventStreamCreate` / `FSEventStreamScheduleWithRunLoop` / `FSEventStreamStart` 返回错误）：指数退避重试（初始 2s，最大 60s，抖动 ±20%），最多 5 次
- [ ] 重试全部失败后降级为定时轮询：每 30s 对已索引目录执行增量扫描（对比 mtime 变化），daemon 日志记录 "实时监控不可用，使用轮询模式"，IPC index_status 返回降级状态
- [ ] FSEventStream 运行中异常停止（kFSEventStreamEventFlagUserDropped / kFSEventStreamEventFlagKernelDropped）：记录丢失事件数，自动重启 stream，若 10 分钟内重启 ≥3 次则降级为轮询
- [ ] 错误日志策略：FSEvents 生命周期事件（启动/停止/重试/降级）写入 `~/.deep-finder/log/fsevents-YYYY-MM-DD.log`，格式 `[HH:mm:ss] [LEVEL] {message}`（LEVEL: INFO/WARN/ERROR），日志文件保留最近 7 天自动轮转

---

### REQ-0.2-04 IndexPersistence 📋 🖥️ P0

**用户场景**：用户退出 app 再打开，搜索即时可用——不需要重新扫描。启动速度 < 1 秒。

**验收标准**：
- [ ] SQLite WAL 模式，路径 ~/.deep-finder/index.db，权限 600
- [ ] 持久化 FileRecord[]（不含索引结构，启动重建）
- [ ] 增量写入：每 5 秒或每 100 条变更批量写入（避免 I/O 抖动）
- [ ] 启动加载 100 万条 < 1s，索引重建 < 2s
- [ ] 退出时 flush 全部未写入变更 + 保存 FSEvents cursor
- [ ] 启动验证使用 `PRAGMA integrity_check`（非自定义 checksum）作为主完整性校验
- [ ] 磁盘空间不足时：停止批量写入，daemon 日志记录警告，继续从内存提供搜索服务（不中断搜索体验）。IPC index_status 返回磁盘空间不足状态
- [ ] Schema 版本管理：`PRAGMA user_version` 跟踪数据库 schema 版本，支持应用更新后自动迁移
- [ ] 迁移操作在事务内执行：`BEGIN` → 迁移 DDL → 更新 `user_version` → `COMMIT`；失败时 `ROLLBACK` 回退到迁移前状态
- [ ] 迁移失败回退：事务 ROLLBACK 后标记索引为损坏，触发全量重建（同 REQ-0.2-05 恢复流程），daemon 日志记录 "数据库迁移失败，正在重建索引..."，IPC index_status 返回重建状态
- [ ] 降级场景检测：`PRAGMA user_version` 高于当前应用版本时，拒绝自动迁移，daemon 日志记录 "索引由更新版本创建，建议删除索引重建"。IPC index_status 返回降级检测状态。v2.0 GUI 提供 "重建索引" 和 "退出" 按钮
- [ ] 单进程访问假设：文档明确标注 index.db 仅由单个 DeepFinder 进程访问，不支持并发多进程写入（WAL 模式下多进程写入可能导致锁冲突）

---

### REQ-0.2-05 索引恢复 📋 🖥️ P1

**用户场景**：异常断电或磁盘错误导致索引损坏。用户看到 "索引需要修复" → 自动修复 → 恢复搜索。

**操作流程**：
1. 启动时加载 SQLite → 校验（行数 + checksum）
2. 校验通过 → 正常启动
3. 校验失败 → daemon 日志记录 "索引损坏，正在重建..." → 全量扫描
4. 重建完成 → 正常使用

**验收标准**：
- [ ] 加载时校验 SQLite 完整性
- [ ] 失败时自动触发全量重建（无需用户手动操作）
- [ ] 重建期间 daemon 日志输出进度（已扫描文件数 / 预估总数）。IPC index_status 返回重建进度
- [ ] 重建完成后自动进入 live 状态
- [ ] WAL 文件损坏而主 DB 完好：删除 WAL + SHM 文件（`index.db-wal`, `index.db-shm`）后重试加载，成功则正常启动（无需全量重建）
- [ ] Checkpoint 失败（写入过程中 WAL 合并失败）：回退为从主 DB 文件单独加载（忽略未 checkpoint 的 WAL 内容），丢失最近未持久化变更，触发增量 FSEvents 补齐
- [ ] Schema 版本不兼容（应用更新后数据库版本过旧）：执行迁移事务（见 REQ-0.2-04），迁移失败则标记索引为损坏并触发全量重建
- [ ] 单进程访问约束：恢复流程假设无其他进程正在写入 index.db；若检测到 SHM 文件被其他进程持有（flock/POSIX lock），等待超时 5s 后判定为残留锁并强制清理

---

## v0.3 — 搜索

### REQ-0.3-01 SearchProvider 协议 📋 🖥️ P0

**用户场景**：无直接感知。但协议设计决定了未来添加新搜索能力（内容搜索、AI 搜索）时，用户无需学习新界面。

**验收标准**：
- [ ] `search(query:) -> AsyncSequence<SearchResult, Never>`
- [ ] `cancel(queryID:)` 取消进行中查询
- [ ] `prepare()` 预热
- [ ] MVP：FileIndexProvider 一次 yield 全部结果
- [ ] 接口兼容未来流式 Provider（AI、内容搜索）

---

### REQ-0.3-02 SearchQuery / SearchResult 📋 🖥️ P0

**用户场景**：用户输入 "Report"（大写 R）→ 结果包含 "report.pdf", "REPORT_FINAL.docx"。大小写不敏感但结果保留原始大小写显示。

**验收标准**：
- [ ] SearchQuery：NFC 统一化 + lowercased
- [ ] SearchResult：record + provider + score(0.0-1.0) + matchType
- [ ] MatchType：exact > prefix > pinyin > substring
- [ ] 大小写不敏感查询，originalName 保留原始大小写用于显示

---

### REQ-0.3-03 SearchCoordinator (actor) 📋 🖥️ P0

**用户场景**：CLI 或 daemon 发起搜索请求后立即获得结果——无防抖、无延迟。体验就像在本地数据库直查。

**验收标准**：
- [ ] 每次查询直接执行（内存索引无防抖）
- [ ] 遍历 ready Providers → 消费 AsyncSequence → 合并结果 → 排序 → 返回
- [ ] 旧查询在新查询发起时自动取消
- [ ] 结果去重（同一文件可能被多个 Provider 返回）
- [ ] 搜索不阻塞：搜索在 actor 隔离上下文执行，不阻塞调用方（CLI/daemon/GUI 均可调用）
- [ ] 每个查询分配单调递增的 sequence number，调用方忽略 stale 查询（sequence number < 当前最新）的结果
- [ ] Provider 超时设定：内存索引 5s，AI Provider 30s；超时后取消查询并返回已收到的部分结果
- [ ] 结果按 FileRecord.ID 去重，同 ID 取优先级最高的 Provider 结果（优先级：MatchType 权重 > score）

---

### REQ-0.3-04 排序策略 📋 🖥️ P1

**用户场景**：用户搜 "report" → 最上面是精确匹配 "report.pdf"，然后是前缀匹配 "report_v2.pdf"，然后是子串匹配 "quarterly_report.xlsx"。**用户最想找的文件排在最前面**。

**验收标准**：
- [ ] 排序权重：MatchType(最高) > 文件名长度(短优先) > 使用频率(高优先) > 修改时间(新优先) > 路径深度(浅优先)
- [ ] 最终 tie-break 使用 FileRecord.ID（稳定、确定性）
- [ ] 文件名排序使用 String.localizedStandardCompare（locale-aware，支持中文/日文自然排序）
- [ ] 自然排序（file1, file2, file10）延后至 v1.3，v0.3 使用 localizedStandardCompare
- [ ] 相同 matchType 时，短文件名优先（"report.pdf" 排在 "annual_report_summary.pdf" 前面）
- [ ] 使用频率：MVP 可不实现，但 FileRecord schema 预留字段

---

### REQ-0.3-05 性能基准测试 📋 🖥️ P0

**用户场景**：用户无感知，但保证每次发布不引入性能退化。

**验收标准**：
- [ ] XCTMetric + measure blocks 编码为自动化测试
- [ ] 100k 文件索引构建 < 3s
- [ ] 1M 文件索引构建 < 10s
- [ ] 前缀查询 p99 < 2ms（1M 记录）
- [ ] 子串查询 p99 < 1ms（1M 记录，3+ 字符查询）。1-2 字符短查询因结果集巨大，p99 < 50ms，结果集截断至前 1000 条
- [ ] 启动加载 1M 文件 < 1s

---

## v0.4 — Daemon + IPC

### REQ-0.4-01 DaemonMain 📋 🖥️ P0

**用户场景**：用户安装 DeepFinder 后，daemon 自动在后台运行。CLI 查询时 daemon 已就绪，搜索即时返回。用户无需手动启动 daemon。

**操作流程**：
1. 首次 CLI 查询 → 检测 daemon 未运行 → 自动 spawn daemon 进程
2. Daemon 启动 → 加载 SQLite 索引 → 重建内存索引 → 启动 FSEventWatcher → 进入 ready 状态
3. Daemon 就绪 → 接受 IPC 连接 → 处理查询
4. 用户关闭系统 → SIGTERM → flush + 退出

**验收标准**：
- [ ] 长驻后台进程，启动时加载 SQLite 索引、重建内存索引、启动 FSEventWatcher
- [ ] SIGTERM 处理器：flush SQLite + 保存 FSEvents cursor + 移除 socket 文件 + 退出（2 秒内完成）
- [ ] PID 文件管理：`~/.deep-finder/daemon.pid`，启动时写入 PID，退出时清理
- [ ] 状态机：starting → ready → live → shutting_down。状态通过 IPC 暴露
- [ ] 单例检测：启动时检查 PID 文件，若 daemon 已运行（PID 存在且进程存活）则拒绝启动并输出友好提示
- [ ] 日志输出到 `~/.deep-finder/log/daemon-YYYY-MM-DD.log`，日志文件保留最近 7 天自动轮转
- [ ] Stale PID 文件检测：PID 文件存在但对应进程不存在时，自动清理 PID 文件并继续启动

---

### REQ-0.4-02 IPCServer 📋 🖥️ P0

**用户场景**：用户运行 `deepfinder "query"` → CLI 通过 IPC 连接 daemon → 获得搜索结果。IPC 协议简洁高效，支持多客户端并发。

**验收标准**：
- [ ] Unix domain socket 服务器：`~/.deep-finder/ipc.sock`
- [ ] 协议：4 字节长度前缀（big-endian UInt32）+ JSON body（Codable-native）
- [ ] 请求类型：query, cancel, stats, config_get, config_set, index_status
- [ ] 响应类型：results, error, stats, ack, index_status
- [ ] 支持多客户端并发连接（基于 Foundation Socket / FileHandle）
- [ ] Socket cleanup：启动时清理残留 socket 文件（若 daemon 未运行）
- [ ] 可通过 `nc -U ~/.deep-finder/ipc.sock` 手动调试（发送 JSON 请求）

---

### REQ-0.4-03 IPCProtocol 📋 🖥️ P0

**用户场景**：无直接感知。协议定义确保 CLI 和 daemon 之间的通信可靠、向前兼容。

**验收标准**：
- [ ] 定义所有 IPC 消息类型的 Codable 结构体：IPCRequest (enum with associated values), IPCResponse (enum with associated values), IPCError
- [ ] JSON 编解码往返零丢失（Codable 自动处理）
- [ ] 协议版本号字段（向前兼容，旧 CLI 可检测新 daemon 版本）
- [ ] 文档化协议规范，支持第三方客户端开发
- [ ] 错误类型细分：daemon_not_ready, query_error, invalid_request, permission_denied

---

### REQ-0.4-04 Daemon 生命周期管理 📋 🖥️ P0

**用户场景**：用户开机后 daemon 自动启动（通过 LaunchAgent），或者首次 CLI 查询时自动 spawn。用户无需关心 daemon 是否运行。

**操作流程**：
1. 用户执行 `deepfinder "query"` → IPCClient 连接 socket
2. [Daemon 运行] → 直接发送查询 → 获得结果
3. [Daemon 未运行] → IPCClient spawn daemon → 等待 ready → 发送查询
4. Daemon 崩溃 → CLI 检测连接断开 → 自动重连或提示

**验收标准**：
- [ ] LaunchAgent 集成：`~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist`（v0.7 `deepfinder install` 安装）
- [ ] CLI 自动启动 daemon：首次查询时检测 daemon 是否运行，未运行则 spawn
- [ ] Daemon 崩溃后 CLI 自动重连（最多重试 3 次，间隔 1s）
- [ ] 自动启动不依赖 LaunchAgent（CLI fallback：直接 spawn daemon 进程）
- [ ] PID 文件锁：检测 stale PID 文件（进程不存在时清理）

---

### REQ-0.4-05 ConfigStore 📋 🖥️ P1

**用户场景**：用户通过 CLI `config` 命令管理配置（排除路径、AI 设置等）。配置持久化，daemon 重启后保留。

**验收标准**：
- [ ] 配置持久化到 `~/.deep-finder/config.json`（权限 600）
- [ ] 配置项：索引排除路径、热键（v2.0 预留）、AI 设置（v3.0 预留）
- [ ] 原子写入：write-to-temp + rename（避免写中断导致损坏）
- [ ] Schema 版本管理（`config_version` 字段）
- [ ] IPC 接口暴露 config_get / config_set（CLI 通过 IPC 读写配置）
- [ ] 默认配置内置在代码中，config.json 不存在时使用默认值

---

## v0.5 — CLI Single-Shot

### REQ-0.5-01 CLIMain Single-Shot 模式 📋 🖥️ P0

**用户场景**：用户在终端输入 `deepfinder "report"` → 即时获得搜索结果列表。类似 `grep` 的即时反馈——执行、输出、退出。

**操作流程**：
1. 用户输入 `deepfinder "report"` → 解析参数
2. 连接 daemon IPC → 发送查询
3. 接收结果 → TerminalFormatter 格式化输出
4. 退出（exit code 反映结果状态）

**验收标准**：
- [ ] `deepfinder "query"` 执行单次搜索，输出结果后退出
- [ ] 参数解析：手动 `CommandLine.arguments`（零外部依赖）
- [ ] 支持 `--json`（结构化 JSON 输出，适合脚本管道）
- [ ] 支持 `--0`（NUL 分隔纯路径输出，适合 `xargs -0`）
- [ ] 支持 `--sort name|size|date`（排序方式）
- [ ] 支持 `--limit N`（限制输出条数）
- [ ] 支持 `--reverse`（逆序排列）
- [ ] 支持 `--verbose`（显示额外信息：匹配类型、评分）
- [ ] 连接 daemon IPC → 发送查询 → 接收结果 → 格式化输出 → 退出
- [ ] Exit codes：0=成功, 1=无结果, 2=daemon 错误, 3=查询错误

---

### REQ-0.5-02 TerminalFormatter 📋 🖥️ P0

**用户场景**：用户搜索结果以美观、易读的格式显示在终端。匹配部分高亮，文件信息一目了然。

**验收标准**：
- [ ] 匹配子串高亮：ANSI bold/color 突出显示匹配位置
- [ ] 文件名保留原始大小写（搜索 "PORT" → "re**port**.pdf"）
- [ ] 路径缩短：`~/` 前缀替换 home 目录路径
- [ ] 文件大小 + 修改日期：ANSI dim 灰显
- [ ] `isatty()` 自动检测：管道/重定向时纯文本输出（无 ANSI escape codes）
- [ ] `--json` 模式：输出结构化 JSON（SearchResult 数组）
- [ ] `--0` 模式：输出 NUL 分隔纯路径（无其他信息）
- [ ] 分页支持：`--limit N` + `--offset M`
- [ ] 拼音匹配时高亮中文字符（搜索 "bg" → **报告**.pdf 高亮 "报告"）
- [ ] 多处匹配全部高亮（"port" 在 "airport_transport_report.pdf" 中 3 处高亮）

---

### REQ-0.5-03 IPCClient 📋 🖥️ P0

**用户场景**：用户无感知 IPC 通信细节。CLI 连接 daemon → 发送查询 → 获得结果。连接失败时有清晰的错误提示。

**验收标准**：
- [ ] 连接 Unix domain socket，发送 IPCRequest，接收 IPCResponse
- [ ] 超时处理：连接超时 5s，查询超时 10s
- [ ] Daemon 未运行时自动启动：spawn daemon 进程 → 等待 ready 信号（最多 10s）→ 连接
- [ ] 重连逻辑：daemon 崩溃后最多重试 3 次，间隔 1s
- [ ] 连接失败友好提示："无法连接 daemon，请运行 `deepfinder daemon start`"

---

### REQ-0.5-04 CLI 参数解析 📋 🖥️ P0

**用户场景**：用户输入 `deepfinder --help` → 看到完整用法文档。输入错误参数 → 友好提示 + 用法示例。

**验收标准**：
- [ ] 手动解析 `CommandLine.arguments`（零外部依赖）
- [ ] 子命令路由：`deepfinder [query]`（single-shot）、`deepfinder`（无参数 = REPL，v0.6）、`deepfinder daemon`（子命令组，v0.7）
- [ ] Flag 解析：`--json`, `--0`, `--sort`, `--limit`, `--reverse`, `--verbose`, `--help`, `--version`
- [ ] 错误处理：未知 flag → 友好错误 + 用法提示（非 crash）
- [ ] `--help` 输出完整用法文档（含示例）
- [ ] `--version` 输出语义化版本号（读自 VERSION 文件）

---

## v0.6 — Interactive REPL

### REQ-0.6-01 REPL 交互循环 📋 🖥️ P0

**用户场景**：用户在终端输入 `deepfinder`（无参数）→ 进入交互模式，持续搜索多个查询，无需每次重新连接 daemon。

**操作流程**：
1. 用户输入 `deepfinder`（无参数）→ 进入 REPL 交互模式
2. 显示 prompt `> ` → 用户输入查询 → 结果即时输出
3. 用户继续输入下一个查询 → 新结果替换旧结果
4. Ctrl+D 或 `:quit` → 退出 REPL

**验收标准**：
- [ ] `deepfinder`（无参数）启动交互模式
- [ ] 使用 Darwin.readline（libedit）实现 prompt 和输入
- [ ] Prompt：`> `（空格后缀）
- [ ] 输入查询 → IPC 查询 → TerminalFormatter 输出结果
- [ ] 支持 Ctrl+C 中断当前查询（不退出 REPL）
- [ ] 支持 Ctrl+D 退出 REPL
- [ ] 历史持久化到 `~/.deep-finder/history`（最近 1000 条）
- [ ] Tab 补全：命令名补全 + 文件路径补全（基于索引查询）

---

### REQ-0.6-02 REPL 命令 📋 🖥️ P0

**用户场景**：用户在 REPL 中输入 `:stats` → 查看索引统计。输入 `:open 3` → 用默认应用打开第 3 个结果。冒号前缀的元命令提供搜索之外的辅助功能。

**验收标准**：
- [ ] `:help` — 显示所有命令及用法
- [ ] `:quit` / `:q` — 退出 REPL
- [ ] `:stats` — 显示索引统计（文件数、索引大小、daemon 状态、索引状态机状态）
- [ ] `:config KEY [VALUE]` — 获取/设置配置项（通过 IPC）
- [ ] `:open N` — 用默认应用打开第 N 个结果（NSWorkspace.shared.open）
- [ ] `:reveal N` — 在 Finder 中显示第 N 个结果（NSWorkspace.shared.selectFile）
- [ ] `:daemon` — 显示 daemon 状态信息（PID、运行时长、连接数）
- [ ] 命令不区分大小写
- [ ] 无效命令 → 友好提示 "未知命令，输入 :help 查看所有命令"

---

### REQ-0.6-03 REPL 历史与导航 📋 🖥️ P1

**用户场景**：用户按上箭头 → 浏览上一个搜索查询。Ctrl+R 搜索历史。Tab 补全命令名或文件路径。

**验收标准**：
- [ ] readline 历史持久化（写入 `~/.deep-finder/history`）
- [ ] 上下箭头浏览历史（readline 内置）
- [ ] Ctrl+R 搜索历史（readline 内置 incremental search）
- [ ] Tab 补全：命令名补全（输入 `:st` → Tab → `:stats`）
- [ ] Tab 补全：文件路径补全（输入部分路径 → Tab → 基于索引查询补全）
- [ ] 历史去重：连续重复查询不记录

---

## v0.7 — Daemon 管理

### REQ-0.7-01 daemon 子命令 📋 🖥️ P0

**用户场景**：用户运行 `deepfinder daemon start` → 启动 daemon。`deepfinder daemon status` → 查看 daemon 运行状态。管理员级别的 daemon 生命周期控制。

**操作流程**：
1. `deepfinder daemon start` → 启动 daemon（若已运行则提示 "daemon already running (PID XXX)"）
2. `deepfinder daemon stop` → 发送 SIGTERM → 等待退出（最多 5s）
3. `deepfinder daemon restart` → stop + start
4. `deepfinder daemon status` → 显示 PID、运行时长、索引状态、连接数

**验收标准**：
- [ ] `deepfinder daemon start`：启动 daemon，若已运行则友好提示
- [ ] `deepfinder daemon stop`：发送 SIGTERM，等待退出（最多 5s），超时则提示 "daemon 未响应，请手动 kill"
- [ ] `deepfinder daemon restart`：stop + start，确保 socket 文件清理后再启动
- [ ] `deepfinder daemon status`：显示 PID、运行时长、索引状态、连接数、索引文件数
- [ ] daemon 未运行时 status 显示 "daemon 未运行"

---

### REQ-0.7-02 config 子命令 📋 🖥️ P1

**用户场景**：用户通过 CLI 管理配置，无需手动编辑 JSON 文件。`deepfinder config list` 查看所有配置，`deepfinder config set exclude_paths /tmp` 添加排除路径。

**验收标准**：
- [ ] `deepfinder config get KEY` — 显示指定配置值
- [ ] `deepfinder config set KEY VALUE` — 设置配置值（通过 IPC 写入 daemon）
- [ ] `deepfinder config list` — 列出所有配置项及当前值
- [ ] `deepfinder config reset` — 恢复默认配置（确认提示）
- [ ] 配置变更后 daemon 热加载（无需重启 daemon）

---

### REQ-0.7-03 install 子命令 📋 🖥️ P1

**用户场景**：用户运行 `deepfinder install` → 安装 LaunchAgent → 开机自动启动 daemon。`deepfinder uninstall` → 移除 LaunchAgent。

**验收标准**：
- [ ] `deepfinder install` — 安装 LaunchAgent plist 到 `~/Library/LaunchAgents/`，实现开机自启 daemon
- [ ] `deepfinder uninstall` — 移除 LaunchAgent plist
- [ ] 已安装时 `install` 提示 "已安装，如需重新安装请先 uninstall"
- [ ] 未安装时 `uninstall` 提示 "未安装"
- [ ] Plist 内容：Label, ProgramArguments（指向 daemon 二进制）, RunAtLoad=true, KeepAlive=false

## v1.0 — CLI Release（首个发布版本）

> **v1.0 是 v0.1–v0.7 功能的总集 + 发布打磨特性**。REQ-0.1 至 REQ-0.7 定义了索引核心、文件系统、搜索、daemon、CLI、REPL、daemon 管理的功能需求（开发阶段），本节定义首次发布时额外需要的打磨功能（CLI 集成测试、模糊纠错、ANSI 高亮匹配、Homebrew formula、man page、shell completions）。只有 v0.1–v0.7 + v1.0 全部完成后才标记为首个发布版本。

### REQ-1.0-01 CLI 集成测试 📋 🖥️ P0

**用户场景**：用户安装 DeepFinder 后，CLI 搜索、daemon 启停、REPL 交互全部可靠工作。集成测试确保端到端功能正确。

**验收标准**：
- [ ] Single-shot 查询测试：`deepfinder "query"` → 正确输出结果（含 ANSI 高亮、JSON 模式、NUL 模式）
- [ ] Exit codes 测试：0=成功, 1=无结果, 2=daemon 错误, 3=查询错误
- [ ] Daemon 生命周期测试：start → status (running) → stop → status (not running)
- [ ] REPL 交互测试：输入查询 → 输出结果，`:help` 显示命令列表，`:quit` 退出
- [ ] JSON 输出结构正确（Codable 编解码验证）
- [ ] 管道模式测试：`deepfinder "query" | cat` → 无 ANSI escape codes
- [ ] Daemon 未运行时自动启动测试

---

### REQ-1.0-02 CLI Release 打包 📋 🖥️ P0

**用户场景**：用户通过 Homebrew 安装 DeepFinder：`brew install deepfinder` → 立即可用。`man deepfinder` 查看完整文档。

**验收标准**：
- [ ] Homebrew formula（Homebrew tap 仓库）
- [ ] Man page（`deepfinder.1`）：完整用法文档，含所有 flag、子命令、示例
- [ ] Shell completions：bash / zsh / fish 自动补全脚本
- [ ] `--version` 输出语义化版本号（读自编译时嵌入的 VERSION）
- [ ] `--help` 完整用法文档（与 man page 内容一致）
- [ ] Binary 包含 DeepFinderDaemon + DeepFinderCLI 两个可执行文件

---

### REQ-1.0-03 模糊纠错 📋 🖥️ P1

**用户场景**：用户打字快，输入 `deepfinder "repotr"` → stderr 显示 "Did you mean: report?" → 用户重新执行正确查询。REPL 模式下按 Tab 接受建议。

**操作流程**：
1. 用户输入 "repotr" → 无精确匹配
2. stderr 输出建议："Did you mean: report?"
3. REPL 模式：按 Tab 接受建议，搜索 "report"
4. Single-shot 模式：用户看到建议后手动重新执行
5. 用户忽略建议 → 查看原始查询结果

**验收标准**：
- [ ] 编辑距离 ≤2 的前缀匹配纠错
- [ ] 建议只在实际无结果或有更优匹配时出现
- [ ] 建议不阻塞当前搜索（用户仍能看到原始查询结果）
- [ ] 纠错延迟 < 10ms（本地算法，无网络）
- [ ] 中文输入：支持拼音纠错（"baogoa" → "baogao"）
- [ ] REPL 模式：建议显示在结果下方，Tab 键接受建议
- [ ] Single-shot 模式：建议输出到 stderr（不干扰 stdout 管道）

---

### REQ-1.0-04 ANSI 高亮匹配 📋 🖥️ P1

**用户场景**：用户搜 `deepfinder "port"` → 结果中 "re**port**.pdf", "air**port**_map.png" 的 "port" 部分用 ANSI 颜色高亮。**用户一眼看到为什么这个文件出现在结果中**。

**验收标准**：
- [ ] 匹配子串用 ANSI bold/color 高亮（终端显示）
- [ ] 保留文件名原始大小写（搜索 "PORT" → "re**port**.pdf"）
- [ ] 多处匹配全部高亮（"port" 在 "airport_transport_report.pdf" 中 3 处高亮）
- [ ] 拼音匹配高亮中文字符（搜索 "bg" → "**报告**.pdf" 高亮 "报告"）
- [ ] `isatty()` 自动检测：管道/重定向时禁用 ANSI 高亮（纯文本输出）
- [ ] `--json` 和 `--0` 模式不包含 ANSI codes

---

## v2.0 — GUI + 扩展索引

> **v2.0 在 v1.0 CLI Release 基础上增加 GUI 前端**。同一个 daemon 进程同时服务 CLI 和 GUI 客户端（通过 IPC）。GUI 通过 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` 请求 Full Disk Access。所有 GUI REQs 通过 IPC 连接同一 daemon，不直接访问索引。

### REQ-2.0-01 SearchPanelView (NSPanel) 📋 🖥️ P0

**用户场景**：按 ⌃⌘K → 一个 Spotlight 风格的搜索面板从屏幕顶部滑出，半透明毛玻璃效果，光晕边框。**第一印象决定用户是否继续用**。

**操作流程**：
1. ⌃⌘K → 面板在当前屏幕顶部居中出现
2. 搜索框自动获得焦点
3. 点击面板外任意位置 / Esc → 面板消失
4. 再次 ⌃⌘K → 面板重新出现，上次的搜索文本保留

**验收标准**：
- [ ] NSPanel 浮动窗口，`.floating` 层级
- [ ] Liquid Glass 材质：`.glassEffect(.regular, in: .rect(cornerRadius: 24))`
- [ ] GlassEffectContainer 统一渲染
- [ ] 当前活跃屏幕居中（非主屏幕）
- [ ] 点击外部 / Esc 自动关闭
- [ ] 关闭后再打开，保留上次搜索文本和光标位置
- [ ] 无标题栏，无 Dock 图标
- [ ] reduceMotion 降级：无动画，直接显示/隐藏
- [ ] 每次热键触发时重新定位面板到鼠标所在屏幕（NSScreen.mouseLocation 匹配）
- [ ] 面板所在显示器断开时，面板自动迁移到主显示器
- [ ] 面板宽度不超过屏幕宽度减去两侧边距（最小 480pt，最大 800pt）
- [ ] NSScreen.main 返回 nil 时 fallback 到 NSScreen.screens[0]
- [ ] 通过 IPC 连接 daemon，不直接访问索引

---

### REQ-2.0-02 SearchBarView 📋 🖥️ P0

**用户场景**：用户看到搜索框 → 直接打字 → 结果即时出现。无需点击搜索按钮，无需按 Enter。

**操作流程**：
1. 面板打开 → 搜索框聚焦，光标闪烁
2. 输入文字 → 下方即时显示结果
3. 点击 ✕ 清除按钮 → 清空搜索框，清空结果
4. 长文字 → 搜索框可水平滚动

**验收标准**：
- [ ] 左侧搜索图标 + SwiftUI TextField（自定义样式）+ 右侧清除按钮。如需 NSTextField 特定行为（如更精细的文本选择/委托），通过 NSViewRepresentable 桥接并记录原因
- [ ] Liquid Glass 材质：`.glassEffect()`
- [ ] 输入即时触发搜索（无防抖），但 CJK 输入法组合期间不触发（监听 hasMarkedText，仅在文本提交后搜索）
- [ ] 清除按钮仅在有文字时显示
- [ ] Placeholder：灰显 "搜索文件..."
- [ ] VoiceOver：Accessibility label "搜索文件"

---

### REQ-2.0-03 ResultsListView 📋 🖥️ P0

**用户场景**：用户输入 "report" → 下方立即出现匹配文件列表，滚动流畅，即使有上千条结果也不卡。

**操作流程**：
1. 输入查询 → 结果列表即时更新
2. ↑↓ 键选择结果，选中项高亮
3. Enter 打开选中文件
4. 滚动到底部 → "还有 234 个结果" 按钮 → 点击加载下一批

**验收标准**：
- [ ] LazyVStack 虚拟化渲染，1000+ 结果滚动 60fps
- [ ] 分页：默认 100 条，底部 "还有 N 个结果" 按钮。最大加载 10,000 条，超出提示 "结果过多，请缩小搜索范围"
- [ ] 查询变更时重置到前 100 条，不论之前加载多少
- [ ] ↑↓ 键盘导航，Enter 打开，Space 预览
- [ ] 选中项视觉高亮（Liquid Glass 效果）
- [ ] 无结果时显示友好提示："未找到匹配文件"
- [ ] 索引构建中显示进度："正在索引... x / y 文件"

---

### REQ-2.0-04 ResultRowView 📋 🖥️ P0

**用户场景**：用户一眼看到文件图标、文件名（匹配部分高亮）、路径、大小和日期。**无需打开文件就能判断是不是要找的文件**。

**验收标准**：
- [ ] 左侧：文件类型图标（FileIconCache 缓存 16x16）
- [ ] 中间上：文件名，匹配部分用系统强调色高亮，保留原始大小写
- [ ] 中间下：路径（相对 ~ 缩短显示），如 `~/Documents/Projects/`
- [ ] 右侧：文件大小 + 修改日期，灰显
- [ ] 目录行：文件夹图标 + 文件名 + 子项数量
- [ ] VoiceOver：读出 "文件名，路径，大小"

---

### REQ-2.0-05 IntelligenceGlow 📋 🖥️ P1

**用户场景**：搜索框获得焦点时，光晕动画让面板看起来有生命力——和 Apple Intelligence 风格一致。用户觉得这是一个精心设计的现代 app。

**验收标准**：
- [ ] AngularGradient：青蓝 / 紫 / 珊瑚粉 / 暖琥珀
- [ ] 4 层叠加（不同线宽 + 模糊半径），旋转周期 ~1.8s
- [ ] 60fps 满帧（M4+ GPU）
- [ ] reduceMotion：降级为静态渐变边框（不旋转）
- [ ] 面板隐藏时暂停动画（避免 GPU 空转）
- [ ] 搜索框聚焦 → 光晕激活；失焦 → 光晕保持但不旋转

---

### REQ-2.0-06 FileIconCache 📋 🖥️ P1

**用户场景**：用户看到每种文件类型有对应的图标——PDF 有 PDF 图标，文件夹有文件夹图标。滚动时图标即时出现不闪烁。

**验收标准**：
- [ ] NSCache 按扩展名缓存 16x16 图标
- [ ] 目录使用文件夹图标
- [ ] 未知类型使用通用文件图标
- [ ] 缓存命中时 < 0.1ms 返回图标
- [ ] 内存可控：NSCache 自动淘汰

---

### REQ-2.0-07 GlobalHotkey (⌃⌘K) 📋 🖥️ P0

**用户场景**：用户在任何应用中按 ⌃⌘K → 搜索面板弹出。这是最高频的操作，必须 100% 可靠。

**操作流程**：
1. 首次启动 → 引导授权 Accessibility（系统弹窗）
2. 授权后 → ⌃⌘K 立即可用
3. 未授权 → 菜单栏图标仍可用，提示授权

**验收标准**：
- [ ] RegisterEventHotKey (Carbon) 优先，CGEventTap fallback
- [ ] 默认 ⌃⌘K，可在 Settings 修改
- [ ] 热键冲突检测：若被占用，提示用户选择其他热键
- [ ] 响应延迟 < 100ms（从按下到面板出现）
- [ ] 首次启动引导授权流程
- [ ] App 在热键权限被拒绝时仍可通过菜单栏图标完全使用
- [ ] 状态栏显示非侵入式指示器提示热键未激活
- [ ] 分别处理 RegisterEventHotKey 和 CGEventTap 失败的独立错误路径
- [ ] 瞬态注册失败的重试逻辑（最多 3 次，指数退避）

---

### REQ-2.0-08 StatusBarController 📋 🖥️ P0

**用户场景**：用户看到菜单栏有个搜索图标 → 点击也能打开搜索面板。不需要记住热键也能使用。

**验收标准**：
- [ ] 菜单栏常驻图标（menu-icon.pdf）
- [ ] 点击 → 打开搜索面板
- [ ] 右键菜单：搜索 / 设置 / 退出
- [ ] 索引状态显示：正常 / 索引中 / 错误

---

### REQ-2.0-09 AppDelegate + GUI 启动流程 📋 🖥️ P0

**用户场景**：用户开机 → DeepFinder GUI 自动启动（Login Item）→ 1 秒内就绪。搜索面板随时可用。

**操作流程**：
1. 系统启动 → GUI app 启动（LSUIElement，无 Dock 图标）
2. 连接 daemon（通过 IPC），daemon 可能已由 LaunchAgent 启动
3. 注册热键 + 菜单栏图标 → 就绪

**验收标准**：
- [ ] GUI 启动到可搜索 < 1s（daemon 已运行时）
- [ ] 支持 Login Item 开机自启
- [ ] LSUIElement=true，不显示 Dock 图标和 Cmd+Tab
- [ ] GUI 启动时自动连接 daemon（IPC），daemon 未运行则自动 spawn
- [ ] GUI 退出时不影响 daemon（daemon 继续后台运行）

---

### REQ-2.0-10 SettingsView 📋 🖥️ P1

**用户场景**：用户想修改热键、排除某些目录、或关闭开机自启。

**验收标准**：
- [ ] 索引排除路径（可添加/删除目录）
- [ ] 热键配置（检测冲突）
- [ ] 开机自启开关
- [ ] 索引状态 + 手动重建按钮
- [ ] 设置通过 IPC 写入 daemon 的 ConfigStore

---

### REQ-2.0-11 Quick Look 预览 📋 🖥️ P1

**用户场景**：用户选中一个文件 → 按 Space → 文件内容预览窗口弹出，不需要打开文件就能确认是不是要找的。

**操作流程**：
1. ↑↓ 选择文件
2. Space → Quick Look 预览窗口
3. 再按 Space / Esc → 关闭预览
4. 预览中可继续 ↑↓ 切换文件

**验收标准**：
- [ ] 支持 QLPreviewPanel：图片/PDF/文本/视频/音频预览
- [ ] Space 打开/关闭预览
- [ ] 预览中 ↑↓ 切换文件，预览内容跟随更新
- [ ] 不支持的文件类型显示文件名 + 大小 + 日期

---

### REQ-2.0-12 右键菜单 📋 🖥️ P1

**用户场景**：用户找到文件后，右键 → "在 Finder 中显示"（打开 Finder 并选中该文件）。

**操作流程**：
1. 右键点击结果行 → 弹出菜单
2. 选择 "在 Finder 中显示" → Finder 打开并选中文件
3. 选择 "复制路径" → 完整路径复制到剪贴板
4. 选择 "打开" → 用默认应用打开文件

**验收标准**：
- [ ] "打开"（默认应用）
- [ ] "在 Finder 中显示"（Reveal in Finder）
- [ ] "复制路径"（完整路径到剪贴板）
- [ ] "获取信息"（Finder Get Info 对话框）
- [ ] 文件不存在时菜单项灰显 + 提示 "文件已移除"

---

### REQ-2.0-13 拖拽支持 📋 🖥️ P2

**用户场景**：用户想把文件拖到邮件附件、聊天窗口或 Finder 文件夹。

**验收标准**：
- [ ] 从结果行拖拽文件到其他应用 → 系统标准拖拽行为
- [ ] 拖拽时显示文件名 badge
- [ ] 支持 NSDraggingSource 协议

---

## v1.1 ~ v1.5 — 详细需求（待补充）

后续版本需求详情按上述模板逐步补充，每个需求包含：
- **用户场景**：什么人在什么情况下用
- **操作流程**：步骤化描述
- **验收标准**：可测试的完成条件

| 版本 | 需求数 | 详细度 |
|------|--------|--------|
| v1.1 — 高级搜索语法 | 7 | 待补充 |
| v1.2 — 元数据过滤 | 8 | 待补充 |
| v1.3 — 搜索体验 | 7 | 待补充 |
| v1.4 — 内容搜索 | 4 | 待补充 |
| v1.5 — 重复查找 | 6 | 待补充 |
| v2.1 — 媒体元数据 | 7 | 待补充 |
| v2.2 — 服务集成 | 6 | 待补充 |

---

## v3.0 — AI 辅助搜索

**核心约束：全部文件不离开本地。只有元数据和用户查询文本可以发送到云端。**

### REQ-3.0-01 AIModelProvider 协议 📋 🖥️ P0

**用户场景**：用户无直接感知。但协议设计确保未来接入新模型（如 GPT-5、Claude）只需新增一个 Provider 文件，不修改现有代码。

**验收标准**：
- [ ] `AIModelProvider: Sendable` 协议：name, capabilities, complete(), translateToSearchSyntax()
- [ ] `AICapability` 枚举：textToSearch / resultSummary / querySuggestion / intentAnalysis / localVision / localSpeech
- [ ] `AIContext` 只包含元数据（FileMetadataSummary），不含文件内容
- [ ] `complete()` 返回 `AsyncThrowingStream<String, Error>` 流式响应
- [ ] Swift 6 严格并发安全

---

### REQ-3.0-02 Privacy Boundary（隐私边界）📋 🖥️ P0

**用户场景**：用户使用 AI 功能时完全放心——文件内容、图片像素、任何二进制数据永不离开本机。用户可通过 CLI `:config ai.data_preview true` 或 Settings 预览实际外传数据。

**验收标准**：
- [ ] `FileMetadataSummary` 只含：name, path(脱敏), size, modifiedAt, extension, localTags
- [ ] 路径脱敏默认开启：`/Users/nadav/` → `~/`
- [ ] 无文件内容字段、无缩略图字段、无二进制数据字段
- [ ] 编译期强制：AIContext 只能引用 FileMetadataSummary，不能引用 FileRecord 的其他字段
- [ ] "数据预览"功能：CLI `deepfinder config get ai.data_preview` 查看实际发送的数据样例（v2.0 GUI: Settings > AI）

---

### REQ-3.0-03 DeepSeek 接入 📋 ☁️ P1

**用户场景**：用户通过 CLI 配置 DeepSeek 作为 AI 引擎（`deepfinder config set ai.model deepseek`），输入自己的 API Key，即可使用自然语言搜索。

**操作流程**：
1. CLI: `deepfinder config set ai.model deepseek`（v2.0 GUI: Settings > AI > 文本模型选择 "DeepSeek"）
2. 输入 API Key（`deepfinder config set ai.api_key <key>`，存储在本地 Keychain，不上传）
3. 开启 "发送文件元数据"（`deepfinder config set ai.send_metadata true`，默认关闭）
4. 回到 CLI/GUI，用自然语言搜索

**验收标准**：
- [ ] DeepSeekProvider 实现 AIModelProvider
- [ ] API Key 存储在 macOS Keychain（不存明文）
- [ ] 网络错误 / API 限流 / Key 无效 → 友好提示，不崩溃
- [ ] 请求超时 30s，超时后降级为纯本地搜索
- [ ] 流式返回（SSE）逐字显示 AI 响应

---

### REQ-3.0-04 千问（Qwen）接入 📋 ☁️ P1

**用户场景**：用户选择千问作为 AI 引擎，体验与 DeepSeek 一致，只是后端不同。

**验收标准**：
- [ ] QwenProvider 实现 AIModelProvider
- [ ] 与 DeepSeek 统一配置接口（CLI `config set ai.model qwen`，v2.0 GUI 下拉切换）
- [ ] API Key 存储在 Keychain
- [ ] 同 REQ-3.0-03 的错误处理和超时机制

---

### REQ-3.0-05 自然语言搜索 📋 🖥️☁️ P0

**用户场景**：用户不想记搜索语法，直接说人话——"找上周修改的超过100MB的视频文件" → 自动翻译为搜索语法并执行。

**操作流程**：
1. 用户输入 "找上周修改的超过100MB的视频文件"
2. AI 异步翻译 → `ext:mp4;mov;mkv dm:lastweek size:>100mb`
3. CLI 输出翻译结果："已翻译为: ext:mp4;mov;mkv dm:lastweek size:>100mb"（REPL 在结果上方显示，single-shot 输出到 stderr）
4. 自动执行翻译后的搜索语法
5. 用户可修改翻译后的语法重新执行

**验收标准**：
- [ ] 自然语言翻译为搜索语法准确率 > 90%（常见场景）
- [ ] 翻译延迟 < 3s（云端 API）
- [ ] 翻译结果可编辑（REPL 可修改后重新执行，v2.0 GUI 可在搜索框修改）
- [ ] AI 不可用时，回退为普通子串搜索（无阻断）
- [ ] 支持中英文自然语言输入

---

### REQ-3.0-06 结果摘要 📋 🖥️☁️ P1

**用户场景**：搜索返回 200 个结果 → AI 自动生成一句话摘要："找到 200 个文件，主要是 PDF 报告和 Excel 表格，大部分在 ~/Documents/Projects/ 下"。用户无需逐条滚动就能了解结果概况。

**操作流程**：
1. 搜索执行 → CLI 在结果上方输出 AI 摘要文本块（v2.0 GUI: 结果列表上方摘要气泡）
2. 摘要异步加载（不阻塞结果显示）
3. 加载完成前 CLI 显示 "AI 分析中..." 状态文本（v2.0 GUI: 骨架屏）

**验收标准**：
- [ ] 摘要基于 FileMetadataSummary 生成（仅文件名/路径/大小/日期）
- [ ] 异步加载，不阻塞本地搜索结果即时显示
- [ ] 摘要 < 100 字，一句话概括结果概况
- [ ] AI 不可用时不显示摘要（CLI 不输出摘要行，v2.0 GUI 不显示气泡，不报错）
- [ ] 摘要缓存：相同查询 5 分钟内不重复请求

---

### REQ-3.0-07 搜索建议 📋 🖥️☁️ P1

**用户场景**：用户搜 "report" → 看到结果后，CLI 输出 AI 建议："您可能在找季度报告，试试 ext:xlsx dm:thisyear"。用户执行建议的搜索语法。

**操作流程**：
1. 用户输入查询 → 本地搜索即时出结果
2. 异步请求 AI：发送查询 + 结果元数据
3. AI 返回建议 → CLI 在结果下方输出建议行（v2.0 GUI: 搜索框下方显示建议气泡）
4. REPL 模式：按 Tab 执行建议查询；single-shot 模式：建议输出到 stderr
5. 用户忽略建议 → 继续当前搜索

**验收标准**：
- [ ] 建议异步加载，延迟 < 5s
- [ ] 不阻塞本地搜索结果
- [ ] REPL 模式：建议可 Tab 接受执行、可忽略
- [ ] 最多显示 1 条建议（避免信息过载）
- [ ] AI 不可用时不显示建议

---

### REQ-3.0-08 语义分组 📋 🖥️☁️ P1

**用户场景**：搜索返回 500 个结果 → CLI 按 AI 分组输出："设计稿 (120)" "合同 (80)" "报告 (200)" "代码 (50)" "其他 (50)"。v2.0 GUI 中可折叠/展开分组。

**验收标准**：
- [ ] 基于文件名/路径元数据的 LLM 分类
- [ ] 分组名称可理解（中文/英文自动适配）
- [ ] 每组显示文件数量
- [ ] "其他" 分组兜底
- [ ] CLI 按分组输出结果；v2.0 GUI 分组可折叠/展开
- [ ] 结果 < 20 条时不分组（无需分组）

---

### REQ-3.0-09 匹配解释 📋 🖥️ P2

**用户场景**：用户看到搜索结果中有一个文件，不确定为什么匹配 → CLI `--verbose` 或 REPL `:explain N` 显示 "匹配原因：文件名含 report，上周修改"。帮助用户理解搜索逻辑。

**验收标准**：
- [ ] CLI `--verbose` 模式在结果旁显示匹配原因；REPL `:explain N` 显示第 N 个结果的匹配原因；v2.0 GUI 悬停显示 tooltip
- [ ] 原因由本地规则生成（无需 AI）：MatchType + 匹配位置 + 元数据条件
- [ ] 格式："匹配原因：{原因}"
- [ ] 不遮挡结果内容

---

### REQ-3.0-10 LocalVisionProvider（本地图片理解）📋 🖥️ P1

**用户场景**：用户有 5000 张照片，想找 "海边的日落" 但文件名是 IMG_20260101.jpg。Vision 框架自动分析每张图片，生成标签 "sunset, beach, ocean" → 用户搜 "sunset" 或 "日落" 就能找到。

**操作流程**：
1. 索引构建时 → 后台对图片文件运行 Vision 框架
2. Vision 识别场景/物体 → 生成标签
3. 标签存入 PinyinIndex/Trie（与文件名同等地位）
4. 用户搜索标签文字 → 命中图片文件

**验收标准**：
- [ ] Vision 框架分析图片 → 生成文本标签（场景/物体/颜色）。注意：VNClassifyImageRequest 仅输出英文标签，中文查询需依赖 REQ-3.0-13 跨语言搜索或本地中英翻译映射
- [ ] 标签写入索引，可被文本搜索命中
- [ ] 完全本地执行，零外传
- [ ] 图片分析不阻塞索引构建（后台低优先级）
- [ ] 支持 JPG/PNG/HEIC/GIF
- [ ] 标签持久化到 SQLite（重启不重复分析）

---

### REQ-3.0-11 以图搜图 📋 🖥️ P1

**用户场景**：用户有一张照片想找类似的照片 → CLI `deepfinder --image photo.jpg` 或粘贴剪贴板图片（v2.0 GUI: 拖入搜索框）→ 显示视觉相似的图片。

**操作流程**：
1. CLI: `deepfinder --image photo.jpg`（v2.0 GUI: 拖入搜索框 / 剪贴板有图片时自动提示）
2. Vision 框架提取图片特征向量
3. 与索引中的图片向量 cosine similarity 匹配
4. 显示 Top-K 最相似的图片

**验收标准**：
- [ ] CLI 支持 `--image <path>` 参数；v2.0 GUI 支持拖入图片 / 剪贴板粘贴图片
- [ ] Vision 框架提取特征，完全本地
- [ ] 返回视觉最相似的 Top 20 图片
- [ ] 搜索延迟 < 500ms（1000 张图片库）
- [ ] 结果按相似度排序，显示相似度百分比

---

### REQ-3.0-12 LocalSpeechProvider（本地语音识别）📋 🖥️ P2

**用户场景**：用户不想打字 → CLI REPL `:listen` 命令或 `--voice` flag（v2.0 GUI: 点击搜索框麦克风图标）→ 说 "找上个月的合同" → 自动填入搜索文字。

**操作流程**：
1. CLI REPL: `:listen` 或 single-shot `deepfinder --voice` → 开始录音（v2.0 GUI: 点击麦克风图标）
2. Speech 框架实时识别语音 → CLI 显示识别文字
3. 说完停顿 1.5s → 自动执行搜索
4. 停止录音

**验收标准**：
- [ ] macOS Speech 框架本地语音识别
- [ ] 支持中英文
- [ ] 实时显示识别中的文字（流式更新）
- [ ] 停顿 1.5s 自动触发搜索
- [ ] CLI Ctrl+C 停止录音（v2.0 GUI: 点击麦克风图标停止）
- [ ] 需要麦克风权限（首次引导授权）

---

### REQ-3.0-13 跨语言搜索 📋 🖥️☁️ P1

**用户场景**：用户输入中文 "设计稿" → 不仅命中 "设计稿_v3.fig"，还能命中 "mockup_final.fig"、"design_spec.pdf"。跨越语言壁垒找到相关文件。

**验收标准**：
- [ ] 中文查询可命中英文同义词文件名（云端翻译）
- [ ] 英文查询可命中中文文件名（拼音已有覆盖，这里增强语义匹配）
- [ ] 翻译结果缓存本地（相同查询不重复请求）
- [ ] AI 不可用时回退为拼音+子串匹配

---

### REQ-3.0-14 自然语言操作 📋 🖥️☁️ P2

**用户场景**：用户说 "把 Downloads 里的截图移到相册文件夹" → AI 理解意图 → 生成操作方案 → 用户确认 → 执行。

**操作流程**：
1. 用户输入自然语言操作指令（CLI REPL 或 GUI）
2. AI 生成操作方案：`移动 ~/Downloads/截图*.png → ~/Pictures/Screenshots/`
3. 显示操作预览：匹配的文件列表 + 目标位置（CLI 输出文件列表到终端，用户输入 y/N 确认；v2.0 GUI 显示预览面板）
4. 用户确认 → 执行移动
5. 操作可撤销（CLI `:undo`，v2.0 GUI Undo 按钮）

**验收标准**：
- [ ] AI 生成操作方案 + 文件列表预览
- [ ] 必须用户确认才执行（CLI y/N 提示，不可自动执行）
- [ ] 支持撤销（CLI `:undo`，v2.0 GUI Undo）
- [ ] 只支持安全的文件操作：移动/复制/重命名（不支持删除）
- [ ] 操作完成后显示结果："已移动 15 个文件"

---

### REQ-3.0-15 用户隐私控制面板 📋 🖥️ P0

**用户场景**：用户想完全控制 AI 功能——哪些数据可以外传、用哪个模型、随时关闭。

**操作流程**：
1. CLI: `deepfinder config set ai.enabled true`（v2.0 GUI: Settings > AI 搜索）
2. 选择文本模型：`deepfinder config set ai.model deepseek`（DeepSeek / Qwen / 关闭）
3. 管理元数据发送权限：`deepfinder config set ai.send_metadata false`
4. 预览外传数据样例：`deepfinder config get ai.data_preview`

**验收标准**：
- [ ] [配置] AI 辅助搜索开关（`ai.enabled`，默认关闭，首次使用引导开启）
- [ ] [配置] 文本模型选择（`ai.model`：deepseek / qwen / off）
- [ ] [配置] 发送文件元数据到云端（`ai.send_metadata`，默认关闭）
- [ ] [配置] 路径脱敏（`ai.path_anonymization`，默认开启）
- [ ] [配置] 本地图片标签生成（`ai.local_vision`，默认开启）
- [ ] [配置] API Key（`ai.api_key`，存储到 Keychain，不存明文）
- [ ] [命令] `deepfinder config get ai.data_preview` 展示实际发送的 JSON 样例
- [ ] 所有 AI 功能默认关闭，用户主动开启才生效

---

### REQ-3.0-16 剪贴板搜索 📋 🖥️ P2

**用户场景**：用户复制了一段文字 → CLI `deepfinder --clipboard` 或 REPL `:paste`（v2.0 GUI: 打开搜索面板自动提示）→ 一键搜索本地包含相似内容的文件。

**操作流程**：
1. 用户复制文字到剪贴板
2. CLI: `deepfinder --clipboard` 或 REPL `:paste`（v2.0 GUI: 搜索框下方出现 "搜索剪贴板内容: '复制的那段文字...'"）
3. 确认 → 执行子串搜索

**验收标准**：
- [ ] 检测剪贴板纯文本内容（忽略图片/文件）
- [ ] 只取前 100 字符显示在建议中
- [ ] 用户点击才执行，不自动搜索
- [ ] 不记录剪贴板历史

---

## v3.1 — 本地 RAG（检索增强生成）

**全部本地执行，零外传。文件内容不离开本机。**

### REQ-3.1-01 文件内容分块 📋 🖥️ P0

**用户场景**：RAG 的基础——将文件内容切成合适大小的文本块，用于后续 embedding。

**验收标准**：
- [ ] 分块策略：256 tokens/chunk，overlap 64 tokens
- [ ] 支持格式：txt, md, pdf, docx, rtf, 代码文件（swift, py, js, ts, java, go, rs）
- [ ] PDF 通过 PDFKit 提取文本
- [ ] docx 通过系统框架提取文本
- [ ] 每个chunk 保留源文件 ID + 偏移量（用于溯源）
- [ ] 二进制文件（图片/视频/音频）跳过

---

### REQ-3.1-02 本地 Embedding 引擎 📋 🖥️ P0

**用户场景**：用户问 "去年收入增长多少" → 本地 Embedding 引擎将查询转为向量 → 匹配最相关的文件块。全程不联网。

**验收标准**：
- [ ] paraphrase-multilingual-MiniLM-L12-v2 CoreML 量化版，模型大小 ~470MB（支持 50+ 语言包括中文）
- [ ] M4 GPU 加速，~1-2ms/chunk（12 层模型比 6 层略慢）
- [ ] 输出 384 维浮点向量
- [ ] 中英文文本均支持（multilingual 模型原生支持）
- [ ] 首次使用时从 bundle 加载模型（或预装）

---

### REQ-3.1-03 向量索引存储 📋 🖥️ P0

**用户场景**：用户无感知。50 万个文件 chunk 的向量索引存储在本地，查询时 cosine similarity Top-K 毫秒级返回。

**验收标准**：
- [ ] SQLite vec 扩展或 hnswlib 存储向量
- [ ] 每个 chunk：向量(384维) + 源文件ID + 偏移量 + 文本预览(50字)
- [ ] 50 万 chunk 向量索引 < 1GB（raw vectors ~0.77GB + metadata）
- [ ] Top-10 查询延迟 < 50ms
- [ ] 支持增量插入（新文件加入时只 embedding 新内容）

---

### REQ-3.1-04 增量 Embedding 更新 📋 🖥️ P1

**用户场景**：用户创建新文件 → 后台自动 embedding 新文件内容 → 下次搜索即可命中。不需要重建全部向量。

**验收标准**：
- [ ] FSEvents 检测文件变更 → 只 embedding 变更文件
- [ ] 文件修改时：删除旧 chunk 向量 → 重新分块 embedding
- [ ] 文件删除时：删除关联的所有 chunk 向量
- [ ] 增量更新不阻塞正常搜索

---

### REQ-3.1-05 语义检索 📋 🖥️ P0

**用户场景**：用户搜索 "团队架构调整方案" → 传统文件名搜索可能找不到（文件名是 "org_change_2026.pdf"）→ 语义检索通过内容理解匹配到该文件。

**操作流程**：
1. 用户输入查询文字
2. Embedding 引擎将查询转为向量
3. 向量索引 cosine similarity Top-K
4. 返回最相关的 chunk + 源文件信息
5. 结果列表显示匹配文件，标注 "语义匹配"

**验收标准**：
- [ ] 查询 → embedding → Top-K 检索全流程 < 100ms
- [ ] 结果包含源文件路径 + 匹配 chunk 预览文本
- [ ] 与文件名搜索结果合并，标注匹配类型（文件名/语义）
- [ ] 语义匹配结果排在文件名精确匹配之后

---

### REQ-3.1-06 本地小模型生成 📋 🖥️ P1

**用户场景**：用户问 "去年收入增长多少" → 本地小模型基于检索到的 chunk 生成回答："根据 Q3_收入分析.xlsx，去年收入增长 23%，主要来自亚太市场。" 回答附带源文件引用。

**操作流程**：
1. 用户输入问题
2. 语义检索 Top-K 相关 chunk
3. 本地 LLM 基于检索 chunk 生成回答
4. CLI 在搜索结果上方输出回答文本块（v2.0 GUI: AI 卡片中显示）
5. 回答中的文件路径可点击/可复制 → 跳转到文件

**验收标准**：
- [ ] Llama 3.2 1B/3B，优先使用 MLX 框架（比 CoreML 更适合 LLM 推理）
- [ ] M4+ 24GB 内存可流畅运行（1B: ~150-250 tok/s, 3B: ~80-105 tok/s via MLX；CoreML 较慢但仍远超 10 tok/s）
- [ ] 生成回答附带源文件路径引用
- [ ] 完全本地，零外传
- [ ] 内存不足时降级：跳过生成，只返回检索结果
- [ ] 生成超时（30s）时中断，显示已生成部分

---

### REQ-3.1-07 RAG 问答 📋 🖥️ P1

**用户场景**：用户用自然语言提问，直接获得基于本地文件内容的回答——不是搜索文件名，而是搜索文件内容。

**操作流程**：
1. 用户在 CLI 输入问题（自动检测是否为问题 vs 关键词搜索）
2. 问题 → 本地 Embedding → 向量检索 → 本地 LLM 生成回答
3. CLI 在结果上方输出回答文本块，引用文件显示为终端可点击路径（v2.0 GUI: 回答卡片显示在搜索框下方）
4. 下方仍显示相关的文件列表

**验收标准**：
- [ ] 自动检测：问号结尾 / 疑问词开头 → 触发 RAG 问答
- [ ] 关键词搜索 → 走正常搜索流程（不走 RAG）
- [ ] CLI 输出回答文本 + 引用文件路径列表；v2.0 GUI 回答卡片：回答文本 + 引用文件列表（可点击）
- [ ] 全流程本地执行
- [ ] 回答生成中显示流式输出（CLI 逐字输出，v2.0 GUI 逐字显示）
- [ ] 无相关文件时回答："未在本地文件中找到相关信息"

---

## 需求统计

| 版本 | P0 | P1 | P2 | P3 | 合计 |
|------|----|----|----|----|------|
| v0.1 | 7 | 0 | 0 | 0 | 7 |
| v0.2 | 4 | 1 | 0 | 0 | 5 |
| v0.3 | 4 | 1 | 0 | 0 | 5 |
| v0.4 | 4 | 1 | 0 | 0 | 5 |
| v0.5 | 4 | 0 | 0 | 0 | 4 |
| v0.6 | 2 | 1 | 0 | 0 | 3 |
| v0.7 | 1 | 2 | 0 | 0 | 3 |
| v1.0 | 2 | 2 | 0 | 0 | 4 |
| v2.0 | 7 | 5 | 1 | 0 | 13 |
| v3.0 | 4 | 8 | 4 | 0 | 16 |
| v3.1 | 4 | 3 | 0 | 0 | 7 |
| **合计** | **44** | **24** | **5** | **0** | **72** |

> v1.1-v1.5 和 v2.1-v2.2 需求待详细展开后补充统计。

---

## 变更日志

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-05-29 | v1.0 | 初始需求列表，107 项 |
| 2026-05-29 | v1.1 | v0.1-v1.0 需求补充用户场景、操作流程、验收标准。改用结构化需求卡格式 |
| 2026-05-29 | v2.0 | CLI-first 重构：v0.4 (Daemon+IPC), v0.5 (CLI single-shot), v0.6 (REPL), v0.7 (daemon 管理)。v1.0 改为 CLI Release。旧 v0.4-v0.5 UI REQs 迁移至 v2.0。v3.0/v3.1 AI REQs 更新 CLI 上下文。72 项 REQ |
