# DeepFinder AI 技术栈设计

**日期**: 2026-06-01
**版本**: v3.1-design
**状态**: planning
**与 v3.1-rag.md 的关系**: 本文档定义 v3.1→v3.3 完整 AI 技术栈演进路线（多提供商、Embedding、VectorStore、OCR、SpeechAnalyzer 等）。`reqs/v3.1-rag.md` 是 v3.1 RAG 部分的 REQ 文件，覆盖文件分块、Embedding、向量索引、语义搜索、本地生成。本设计文档中 Phase 1 的 RAG 相关步骤对应 v3.1-rag.md 中的 REQ-3.1-01~07；Phase 1 中多提供商、OCR、SpeechAnalyzer 等非 RAG 功能目前无独立 REQ 文件，待 v3.1 开发时按需补充。
**作者**: AI Architect Team (Bruce + workflow agents)

## 1. 概述

### 1.1 背景

DeepFinder v3.0 已完成基础 AI 能力：DeepSeek + Qwen 云 LLM、Vision 图像标记、Speech 语音识别、NL 搜索翻译、结果摘要、语义分组、跨语言搜索。当前 AI 模块共 29 个源文件，架构上采用 `AIModelProvider` 协议抽象所有 AI 后端。

v3.0 的局限：
- **无本地文本 LLM**：所有文本 AI（翻译、摘要、分组）依赖云 API
- **无向量 Embedding**：语义搜索靠 LLM 翻译成关键词，非稠密向量检索
- **暴力图像相似度**：O(n) 线性扫描，不可扩展

### 1.2 目标

定义 v3.1→v3.3 的 AI 技术栈演进路线，在 **零外部依赖约束** 下最大化设备端能力，云 API 作为可选增强。

### 1.3 关键约束

| 约束 | 说明 |
|------|------|
| **零外部依赖** | 纯 Swift + Apple 框架，不引入第三方包 |
| **隐私优先** | 文件路径/名称/内容默认不出设备 |
| **Apple AI 区域差异** | Apple Intelligence / FoundationModels 在中国大陆等区域可能不可用，设备端 AI 只做兜底或用户可选 |
| **双 Tier 共享** | CLI + GUI 共用 daemon 中的 AI 逻辑，差异仅在呈现层 |
| **中文为主** | 主要用户中文语境，中英双语文件 |
| **速度第一** | 搜索延迟 <100ms，AI 增强不能阻塞搜索 |

---

## 2. 技术选型

### 2.1 LLM 策略

**核心原则**：Provider-agnostic 架构 — 用户可选择任何主流 AI 提供商。设备端兜底（有则用），云主路径（全区域一致）。

#### 2.1.1 支持的提供商

**OpenAI 兼容协议**（复用 `OpenAICompatibleProvider`，配置 endpoint + model name 即可）：

| 提供商 | 推荐模型 | 中文质量 | Embedding API | 说明 |
|--------|----------|----------|---------------|------|
| **Qwen** (通义千问) | Qwen3.6-Plus | ⭐⭐⭐⭐⭐ SOTA | ✅ text-embedding-v4 | 中文最强, 1M ctx, 全区域 |
| **DeepSeek** | V4-Pro | ⭐⭐⭐⭐⭐ 优秀 | ❌ 无 | 价格最低, 1M ctx |
| **智谱** (GLM) | GLM-5.5-Plus | ⭐⭐⭐⭐ 很好 | ✅ Embedding-3 | 国产, 中文优化, 工具调用强 |
| **OpenAI** | GPT-5.1 | ⭐⭐⭐ 良好 | ✅ text-embedding-3 | 全球生态最成熟 |
| **Moonshot** (Kimi) | Kimi-K2 | ⭐⭐⭐⭐ 很好 | ❌ 无 | 超长上下文, 中文优秀 |
| **MiniMax** | MiniMax-Text-01 | ⭐⭐⭐⭐ 很好 | ❌ 无 | 国产, 456B 参数 |
| **任何 OAI 兼容** | — | 取决于提供商 | 取决于提供商 | 用户自定义 endpoint |

**自定义协议**（需独立 provider 实现）：

| 提供商 | 推荐模型 | 中文质量 | Embedding API | 协议格式 |
|--------|----------|----------|---------------|----------|
| **Anthropic** (Claude) | Claude Opus 4.5 | ⭐⭐⭐ 良好 | ❌ 无 (需 Voyage AI) | Messages API (非 OAI) |
| **Google** (Gemini) | Gemini 2.5 Pro | ⭐⭐⭐ 良好 | ✅ text-embedding-004 | Gemini API (非 OAI) |

**设备端**：

| 方案 | 模型 | 中文质量 | 说明 |
|------|------|----------|------|
| **Apple 设备端** | LanguageModelSession (~3B) | ⭐⭐ 基础 | macOS 26, 仅在有区域支持时兜底 |
| **MLX 本地** (未来) | Qwen3.5-7B/30B | ⭐⭐⭐⭐⭐ 优秀 | 需引入 MLX Swift, 按需评估 |

#### 2.1.2 配置模型

```
# 提供商选择
ai.model = "auto"        # 默认：自动选择 (见 2.6 路由逻辑)
ai.model = "qwen"        # 通义千问
ai.model = "deepseek"    # DeepSeek
ai.model = "zhipu"       # 智谱 GLM
ai.model = "openai"      # OpenAI
ai.model = "moonshot"    # Moonshot Kimi
ai.model = "minimax"     # MiniMax
ai.model = "anthropic"   # Claude
ai.model = "gemini"      # Google Gemini
ai.model = "custom"      # 用户自定义 OAI 兼容 endpoint
ai.model = "apple"       # Apple 设备端 (不可用时降级提示)
ai.model = "off"         # 关闭文本 AI

# 自定义 endpoint (仅 ai.model=custom 时生效)
ai.customEndpoint = "https://api.example.com/v1"
ai.customModelName = "model-name"
ai.customAPIKey = "sk-..."

# Embedding 提供商 (可独立于 LLM 选择)
ai.embeddingModel = "qwen"      # Qwen text-embedding-v4
ai.embeddingModel = "zhipu"     # 智谱 Embedding-3
ai.embeddingModel = "openai"    # OpenAI text-embedding-3
ai.embeddingModel = "gemini"    # Google text-embedding-004
ai.embeddingModel = "nlcontextual" # Apple 设备端 (零依赖)
ai.embeddingModel = "off"       # 关闭语义搜索
```

#### 2.1.3 架构：Provider-Agnostic

```
              AIModelProvider (protocol)
                     │
         ┌───────────┼───────────┬──────────────┐
         ▼           ▼           ▼              ▼
  OpenAICompat    Anthropic    Gemini       AppleOnDevice
  Provider        Provider     Provider     Provider
  ┌──────────┐   (Messages    (Gemini      (Language
  │ Qwen     │    API)        API)         ModelSession)
  │ DeepSeek │
  │ 智谱     │
  │ OpenAI   │
  │ Moonshot │
  │ MiniMax  │
  │ custom   │
  └──────────┘
```

- `OpenAICompatibleProvider` — 覆盖 80% 的提供商，仅需配置 endpoint + model + API key
- `AnthropicProvider` — 新增，Messages API，需处理不同的 SSE 格式
- `GeminiProvider` — 新增，Gemini API，需处理不同的请求/响应格式
- `AppleOnDeviceProvider` — 新增，FoundationModels，设备端兜底
- 新增提供商只需实现 `AIModelProvider` 协议的两个方法

**AIModelProvider 协议增强**：
```swift
protocol AIModelProvider {
    // 现有
    func complete(prompt: String, context: AIContext) -> AsyncThrowingStream<String, Error>
    func translateToSearchSyntax(_ nlQuery: String) async throws -> String
    var capabilities: AICapability { get }

    // 新增
    var displayName: String { get }          // 用于 UI/CLI 显示
    var supportsOnDevice: Bool { get }       // 是否设备端
    var contextLimit: Int { get }            // token 上限，调用方截断
    var hasEmbeddingAPI: Bool { get }        // 是否有 Embedding API
}
```

### 2.2 Embedding 策略

**核心原则**：为语义搜索提供向量化能力。Embedding 提供商可独立于 LLM 选择。设备端兜底（零依赖），云可选。

| 角色 | 方案 | 维度 | 说明 |
|------|------|------|------|
| **Qwen** | text-embedding-v4 | 64-2048 (可配置) | 中文最佳, $0.07/1M tokens, OAI 兼容 |
| **智谱** | Embedding-3 | 1024/2048 | 国产, 中文优化, OAI 兼容 |
| **OpenAI** | text-embedding-3-small/large | 512/1536/3072 | 生态最成熟 |
| **Google** | text-embedding-004 | 768 | Gemini 生态 |
| **设备端兜底** | NLContextualEmbedding | 512 | macOS 14+, .cjk+.latin 双模型, 零依赖 |
| **未来升级** | CoreML Qwen3-Embedding | 1024 | 捆绑到 App, 全设备端, ~200MB |

**新增 EmbeddingProvider 协议**：
```swift
protocol EmbeddingProvider {
    func embed(text: String) async throws -> [Float]
    func embedBatch(texts: [String]) async throws -> [[Float]]
    var dimensions: Int { get }
}
```

**实现**：
- `CloudEmbeddingProvider` — OAI 兼容通用实现 (Qwen / 智谱 / OpenAI), opt-in, 文件名仅
- `NLEmbeddingProvider` — NLContextualEmbedding, .cjk + .latin 双模型路由, 零依赖
- `GeminiEmbeddingProvider` — Google text-embedding-004 (Gemini API 格式)
- `CoreMLEmbeddingProvider` — 未来, 捆绑模型

### 2.3 向量存储

| 角色 | 方案 | 说明 |
|------|------|------|
| **主路径** | FlatFileVectorStore + BNNSVectorSearch | mmap Float32 文件, AMX/NEON 加速, 零依赖 |
| **未来升级** | sqlite-vector | 静态编译, NEON SIMD, 量化支持, 需 vend C 文件 |

**新增 VectorStore 协议**：
```swift
protocol VectorStore {
    func insert(id: FileRecord.ID, vector: [Float]) async throws
    func search(query: [Float], topK: Int) async throws -> [(FileRecord.ID, Float)]
    func delete(id: FileRecord.ID) async throws
    func count() async -> Int
}
```

**规模估算**：
- 512-dim × Float32 = 2KB / 文件
- 50 万文件 = 1GB 向量文件
- M4 上 BNNS 暴力搜索 10 万向量 ~20-50ms
- 超过 50 万文件时建议升级 sqlite-vector

### 2.4 Vision 策略

全部设备端，不受 Apple Intelligence 区域限制。

| 组件 | 技术 | 状态 |
|------|------|------|
| 图像分类 | VNClassifyImageRequest (~1500 标签) | ✅ 保持 |
| 视觉相似 | VNGenerateImageFeaturePrintRequest (768-dim) | ✅ 保持 |
| **OCR 文本提取** | RecognizeDocumentsRequest (macOS 26 新增) | 🆕 添加 |
| **语义图像理解** | ViTDet-L Vision Encoder (FoundationModels, macOS 26) | 🆕 添加 |
| **视频帧分析** | AVAssetImageGenerator + Vision requests | 🆕 添加 |

**OCR Pipeline** (`Sources/AI/OCRPipeline.swift`)：
- 文件摄入时对 image/png/jpg/heic/pdf 运行 RecognizeDocumentsRequest
- 提取段落/表格结构化文本，存入 SQLite ExtractedText
- 通过 FullSubstringMap 使截图文本可搜索
- 回退: VNRecognizeTextRequest (非文档类图像)

**语义图像嵌入** (`Sources/AI/SemanticImageEmbedder.swift`)：
- ViTDet-L 300M 生成语义 Embedding（"这是一只狗在公园玩"）
- 与特征打印互补：语义理解 vs 视觉相似
- 实现 "找我的狗的照片" 而非 "找跟这张图看起来像的"

**视频帧提取** (`Sources/AI/VideoFrameExtractor.swift`)：
- AVAssetImageGenerator 每 5 秒抽取关键帧
- 馈入现有 Vision 请求（分类 + OCR + 特征打印 + 语义嵌入）
- 聚合：主导标签、所有提取文本、代表性帧时间戳

### 2.5 Speech 策略

全部设备端，零云依赖。

| 角色 | 技术 | 说明 |
|------|------|------|
| **主路径** | SpeechAnalyzer (macOS 26) | 无时长限制, 自动语言检测, 设备端 |
| **回退** | SFSpeechRecognizer | requiresOnDeviceRecognition=true, ~1 分钟限制 |
| **按需** | WhisperKit (large-v3) | 中英混合 code-switching, ~3GB 模型, MIT license |

**双语策略**：
- SpeechAnalyzer 自动语言检测可能消除双实例需求
- 如不够：zh-CN 实例优先，en-US 回退
- WhisperKit 仅在实测 code-switching 准确率不足时启用

### 2.6 云 vs 设备端决策矩阵

```
查询进入 → ai.model 配置检查
  ├─ "off" → 无 AI，直接关键词搜索
  ├─ "apple" → 检查区域支持 → 可用则用，不可用降级提示
  ├─ 具体提供商名 → 直接使用该云 API
  ├─ "custom" → 使用 ai.customEndpoint 配置的 endpoint
  └─ "auto" → 按优先级尝试（首个可用即用）:
       ├─ Qwen (中文最强, 全区域可用, 有 Embedding)
       ├─ 智谱 (国产备选, 中文优秀, 有 Embedding)
       ├─ DeepSeek (价格最低, 无 Embedding)
       ├─ OpenAI (全球通用)
       └─ Apple 设备端 (兜底, 区域受限)

Embedding 路由 (独立于 LLM):
  ├─ ai.embeddingModel = "qwen"|"zhipu"|"openai"|"gemini" → 对应云 API
  ├─ ai.embeddingModel = "nlcontextual" → Apple 设备端 (零依赖, 默认)
  └─ ai.embeddingModel = "off" → 无语义搜索

其他能力路由 (不受 LLM 配置影响):
  ├─ Vision/OCR: 始终设备端 (不受区域限制)
  ├─ Speech: 始终设备端 (不受区域限制)
  └─ 跨语言: LLM (质量) → 拼音+子串兜底
```

---

## 3. 双 Tier 设计

### 3.1 架构原则

**所有 AI 逻辑在 daemon 进程，CLI 和 GUI 通过 IPC 共享，零代码重复。**

```
┌─────────────────────────────────────────────────┐
│                    Daemon                        │
│  ┌───────────────────────────────────────────┐  │
│  │  AI Module                                │  │
│  │  ├─ AIModelProvider (Qwen/DeepSeek/Apple) │  │
│  │  ├─ EmbeddingProvider + VectorStore       │  │
│  │  ├─ Vision Pipeline (OCR/Classify/Embed)  │  │
│  │  ├─ Speech Engine (Analyzer/Recognizer)   │  │
│  │  ├─ NLSearchTranslator                    │  │
│  │  ├─ ResultSummarizer / SearchAdvisor      │  │
│  │  └─ SemanticGrouper / CrossLanguage       │  │
│  └───────────────────────────────────────────┘  │
│                      │ IPC                       │
└──────────────────────┼──────────────────────────┘
           ┌───────────┴───────────┐
           ▼                       ▼
     ┌──────────┐           ┌──────────┐
     │ CLI Tier │           │ GUI Tier  │
     │ (程序员)  │           │ (普通用户) │
     └──────────┘           └──────────┘
```

### 3.2 CLI Tier

程序员视角，速度优先，可脚本化。

| 功能 | 实现 |
|------|------|
| NL 查询 | `deepfinder 'find big videos from last week'` |
| JSON 输出 | `--json` 添加 `ai_translated_query`, `ai_summary`, `ai_groups` |
| AI 状态 | `:stats` 显示提供商、设备端/云状态、向量索引大小 |
| 配置 | `deepfinder config set ai.model auto/qwen/deepseek/zhipu/openai/moonshot/minimax/anthropic/gemini/custom/apple/off` |
| 强制云 | `deepfinder --cloud 'complex query'` |
| 数据预览 | `deepfinder config get ai.data_preview` |

### 3.3 GUI Tier

普通用户视角，自然交互，可发现性。

| 功能 | 实现 |
|------|------|
| SpeechOverlay | 语音输入时 waveform 动画 + 部分转录 + 语言指示器 |
| AI 设置面板 | 模型选择、API Key 输入（Keychain 状态）、数据预览开关 |
| 首次引导 | "启用设备端 AI？"（默认是）→ "添加云 AI 提升质量？"（opt-in）+ 隐私说明 |
| IntelligenceGlow | AI 处理时 Liquid Glass 面板增强发光效果 |
| 搜索栏适配 | "搜索文件..." → "用 AI 搜索文件..."（AI 启用时） |
| 右键菜单 | "搜索相似图片" → ImageSimilaritySearch, "摘要这些结果" → ResultSummarizer |
| 确认对话框 | NL 文件操作 (move/copy/rename) 弹出 NSAlert 确认 |

---

## 4. 基础设施变更

### 4.1 新增文件

#### Already implemented in v3.0

| 文件 | 用途 |
|------|------|
| `Sources/AI/EmbeddingProvider.swift` | Embedding 生成协议 |
| `Sources/AI/VectorStore.swift` | 向量存储协议 |
| `Sources/AI/NLEmbeddingProvider.swift` | NLContextualEmbedding 实现 (双模型 .cjk+.latin) |
| `Sources/AI/CloudEmbeddingProvider.swift` | 云 Embedding 通用实现 (OAI 兼容: Qwen/智谱/OpenAI) |
| `Sources/AI/AnthropicProvider.swift` | Claude Messages API 实现 |
| `Sources/AI/GeminiProvider.swift` | Google Gemini API 实现 |
| `Sources/AI/ProviderRegistry.swift` | 提供商注册/发现/auto 路由 |
| `Sources/AI/PromptLoader.swift` | Prompt 外部化加载器 |
| `Sources/AI/Prompts/*.txt` | 外部化 prompt 文件 (search_translation, result_summary, query_suggestion, semantic_grouping) |

#### New for v3.1+

| 文件 | 用途 |
|------|------|
| `Sources/AI/FlatFileVectorStore.swift` | mmap + BNNSVectorSearch 实现 |
| `Sources/AI/AppleOnDeviceProvider.swift` | FoundationModels LanguageModelSession 实现 |
| `Sources/AI/OCRPipeline.swift` | RecognizeDocumentsRequest OCR 管道 |
| `Sources/AI/SemanticImageEmbedder.swift` | ViTDet-L 语义图像嵌入 |
| `Sources/AI/VideoFrameExtractor.swift` | AVAssetImageGenerator 视频帧提取 |
| `Sources/AI/SpeechAnalyzerProvider.swift` | SpeechAnalyzer (macOS 26) 实现 |
| `Sources/AI/AITelemetry.swift` | 隐私保护的 AI 遥测 (OSLog, opt-in) |

### 4.2 现有文件修改

| 文件 | 变更 |
|------|------|
| `AIModelProvider.swift` | +`supportsOnDevice`, +`contextLimit`, +`onDeviceTextAI` capability |
| `AIConfig.swift` | +`cloudFallback`, +`embeddingModel`, +`cacheTTL`, +`customEndpoint`, +`customModelName`, +`customAPIKey`；工厂方法；提供商验证 |
| `AIContext.swift` | +`contentSnippets` (仅设备端), +`FileSnippet`, IndexStats 增强 |
| `DeepSeekProvider.swift` | Prompt 外部化；指数退避重试 (1s→30s, 3次)；token 计数；rate limit header 解析 |
| `HTTPClient.swift` | +`cancelRequest(id:)`, +`requestTimeout`, +response headers, dataTask 替代 data(for:) |
| `FileMetadataSummary.swift` | /Volumes 路径匿名化, +`contentSnippet` (设备端门控) |

### 4.3 缓存可配置化

| 组件 | 当前 | 变更 |
|------|------|------|
| ResultSummarizer | 5min (编译时常量) | 读 AIConfig.cacheTTL (默认 300s, 范围 60-3600s) |
| CrossLanguageSearch | 1hr (编译时常量) | 读 AIConfig.cacheTTL × 12 (默认 3600s, 范围 300-86400s) |
| SemanticGrouper | 20 结果阈值 (编译时常量) | 读 AIConfig (新键 `ai.groupingThreshold`, 范围 5-50) |

---

## 5. 迁移路线

### Phase 1: v3.1 — 协议 + 多提供商 + 增强基础 (3-4 周)

**目标**：引入 Embedding/Vector 协议，Provider-agnostic 多提供商支持，OCR/SpeechAnalyzer，零新依赖。

| 步骤 | 内容 | 验证 |
|------|------|------|
| 1 | EmbeddingProvider + VectorStore 协议 | 编译通过，现有代码不变 |
| 2 | ProviderRegistry: 提供商注册/发现/auto 路由 | 单测: auto 优先级、provider 别名解析 |
| 3 | AnthropicProvider: Claude Messages API + SSE | 单测: mock HTTP, 流式响应解析 |
| 4 | GeminiProvider: Google Gemini API | 单测: mock HTTP, 非 OAI 格式转换 |
| 5 | CloudEmbeddingProvider: OAI 兼容通用实现 (Qwen/智谱/OpenAI) | 单测: 多 provider endpoint 切换, 维度验证 |
| 6 | NLEmbeddingProvider (.cjk + .latin 双模型) | 单测: 中/英/混合文本 embedding, 512-dim |
| 7 | FlatFileVectorStore (mmap + BNNS) | 单测: 1万向量插入+搜索, 性能: 10万向量 <50ms |
| 8 | AppleOnDeviceProvider (LanguageModelSession) | 集成测试: NL 查询翻译质量 vs 云基线 |
| 9 | Prompt 外部化到 Prompts/*.txt | 现有云 provider 测试仍通过 |
| 10 | OCRPipeline (RecognizeDocumentsRequest) | 单测: 截图文本提取, 中英混合 |
| 11 | SpeechAnalyzerProvider | 集成测试: 中英文转录, 无时长限制 |
| 12 | AIConfig 工厂方法 + 新键 (含 custom endpoint) | 配置 round-trip 测试 |
| 13 | OpenAICompatibleProvider 重试/退避 | 单测: mock HTTP 429 → 验证退避 |
| 14 | AITests (新组件全覆盖) | 测试通过, 覆盖率 >80%, 现有测试仍通过 |

### Phase 2: v3.2 — 语义搜索 + Vision 增强 (2-3 周)

**目标**：向量语义搜索上线，Vision 管道完整。零新依赖。

| 步骤 | 内容 |
|------|------|
| 1 | 文件扫描时构建语义索引 (NLEmbeddingProvider → FlatFileVectorStore) |
| 2 | SemanticSearcher: 向量 + 关键词联合/交叉搜索模式 |
| 3 | SemanticImageEmbedder (ViTDet-L, macOS 26) |
| 4 | VideoFrameExtractor (AVAssetImageGenerator + Vision) |
| 5 | AITelemetry (OSLog, opt-in) |
| 6 | GUI AI 设置面板更新 |

### Phase 3: v3.3+ — 按需质量升级 (证据驱动)

**仅在实测证明需要时才执行**。不做预先建设。

| 触发条件 | 行动 |
|----------|------|
| NLContextualEmbedding 语义质量不足 (recall@10 < 0.7) | CoreML Qwen3-Embedding 捆绑 (~200MB) |
| 向量 >50 万且暴力搜索 >100ms | sqlite-vector 静态编译 |
| 中英混合语音 code-switching 准确率不可接受 | WhisperKit large-v3 (~3GB) |
| 用户主动要求云 Embedding + 知情同意 | QwenEmbeddingProvider (opt-in) |

---

## 6. 风险评估

### R1: NLContextualEmbedding 语义质量不足
- **严重度**: Medium
- **影响**: 语义搜索结果差，用户关闭 AI
- **缓解**: 上线前用 1 万双语文件名做基准测试，recall@10 目标 ≥0.7。不达标则直接跳到 CoreML Qwen3-Embedding
- **兜底**: Cloud Qwen Embedding (匿名化文件名 + 显式同意)

### R2: 隐私边界被突破
- **严重度**: Critical
- **影响**: 文件内容泄露到云 API，核心隐私承诺失效
- **缓解**: contentSnippets 编译时门控 (`guard provider.supportsOnDevice`)。云 provider 添加 debug 断言 (contentSnippets 非 nil → crash)。专用单测验证云 provider 永远收不到 contentSnippets
- **兜底**: 移除 contentSnippets 功能

### R3: 暴力向量搜索扩展性
- **严重度**: Medium
- **影响**: 50 万文件时搜索延迟 ~100ms，100 万 ~200ms
- **缓解**: Top-K 限制 (K=100), M4 基准实测, `:stats` 监控向量数量。超过 50 万时日志建议升级 sqlite-vector
- **兜底**: 加速 sqlite-vector 迁移 (量化 4-5x 加速)

### R4: macOS 26 API 稳定性
- **严重度**: Low
- **影响**: FoundationModels/SpeechAnalyzer/RecognizeDocumentsRequest 在 beta 期间 API 变动
- **缓解**: 所有新 API 包装在协议后，`if #available(macOS 26, *)` 守卫。云 provider 作为始终可用的回退
- **兜底**: 如关键 API 从 macOS 26 正式版移除，回退到云 provider

### R5: LLM 服务质量不一致
- **严重度**: Medium
- **影响**: 不同 AI 后端（Qwen Cloud / DeepSeek Cloud / Apple 设备端）的翻译质量存在差异，auto 模式在不同区域可能路由到不同后端，用户体验不一致
- **缓解**: auto 模式默认 Qwen Cloud 主路径（质量最高且全区域一致），Apple 设备端仅做兜底。结果显示提供商来源（"Translated by: Qwen Cloud"）。支持 `--cloud` 强制云，`--local` 强制设备端
- **兜底**: 如 Apple 设备端质量持续不可接受，在 auto 模式中降低其优先级或完全跳过

### R6: Apple AI 区域不可用
- **严重度**: Medium
- **影响**: 中国大陆等区域 FoundationModels 不可用，设备端 LLM 功能失效
- **缓解**: auto 模式自动检测并跳过设备端，直接使用云。用户选择 "apple" 时明确提示区域限制
- **兜底**: Cloud provider (Qwen/DeepSeek) 全区域可用，作为始终可用的主路径

---

## 7. 测试策略

### 7.1 新增测试文件

| 测试文件 | 覆盖 |
|----------|------|
| `Tests/AITests/EmbeddingProviderTests.swift` | NLEmbeddingProvider: 中/英/混合文本, 维度, 余弦相似度 |
| `Tests/AITests/VectorStoreTests.swift` | FlatFileVectorStore: 插入/搜索/删除/计数, 10K 性能基准 |
| `Tests/AITests/AppleOnDeviceProviderTests.swift` | Mock LanguageModelSession, 翻译质量对比 |
| `Tests/AITests/OCRPipelineTests.swift` | 中英混合截图文本提取, FullSubstringMap 集成 |
| `Tests/AITests/SpeechAnalyzerProviderTests.swift` | Mock SpeechAnalyzer, 自动语言检测 |
| `Tests/AITests/VideoFrameExtractorTests.swift` | 帧提取, Vision 集成 |
| `Tests/AITests/AITelemetryTests.swift` | 遥测正确性, PII 验证 |

### 7.2 隐私回归测试

```swift
func testCloudProviderNeverReceivesContentSnippets() { ... }
func testCloudEmbeddingOnlySendsFilenames() { ... }
func testPathAnonymizationAppliedBeforeCloudSend() { ... }
```

---

## 8. 参考

- 当前 AI 模块: `Sources/AI/` (21 files)
- 当前 AI 测试: `Tests/AITests/`
- 主架构 spec: `docs/superpowers/specs/2026-05-26-deep-finder-design.md`
- v3.0 AI spec: `docs/superpowers/specs/reqs/v3.0-ai.md`
- v3.1 RAG spec: `docs/superpowers/specs/reqs/v3.1-rag.md`
- 产品配置: `PRODUCT.toml` + `Sources/Index/ProductConfig.swift`
