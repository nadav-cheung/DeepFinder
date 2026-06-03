# AI-Powered Search

## You want to use AI-powered search

DeepFinder v3.0 adds AI-powered semantic search, natural language understanding, and local intelligence. This guide covers how to enable and use each AI feature.

---

## Enable AI Features

AI cloud features require an API key. Multiple providers are supported:

| Provider | Model | Endpoint |
|----------|-------|----------|
| **DeepSeek** | `deepseek-chat` | `api.deepseek.com` |
| **Qwen** (Tongyi Qianwen) | `qwen3.6-plus` | `dashscope.aliyuncs.com` |
| **Zhipu** (智谱 GLM) | `glm-4` | `open.bigmodel.cn` |
| **OpenAI** | `gpt-4o` | `api.openai.com` |
| **Moonshot** (Kimi) | `moonshot-v1` | `api.moonshot.cn` |
| **MiniMax** | `abab6.5s` | `api.minimax.chat` |
| **Anthropic** (Claude) | `claude-sonnet-4-6` | `api.anthropic.com` |
| **Google Gemini** | `gemini-2.5-pro` | `generativelanguage.googleapis.com` |
| **Apple On-Device** | Local only | N/A (no API key needed) |

AI features use a single unified API key. DeepFinder stores it securely in a file-backed secrets store (`~/.deep-finder/.env`, permissions 600) — not in plaintext in the settings file.

```bash
# Enable AI and choose a provider
deepfinder config set ai.enabled true
deepfinder config set ai.model deepseek
# Set your API key (stored securely)
deepfinder config set ai.apiKey "sk-..."
```

No AI features are active until you configure a key. **All local AI features (vision tagging, speech input, clipboard search, match explanation) work without any API key.**

---

## Natural Language Search

When an AI provider is configured, you can type queries in plain English instead of search syntax. The `NLSearchTranslator` detects whether your input is already valid search syntax (skipping translation) or natural language (invoking the AI provider).

```bash
# These natural language queries are automatically translated:
deepfinder "find large video files from last week"
# → AI translates to: ext:mp4;mov;mkv dm:lastweek size:>100mb

deepfinder "photos of sunsets from my vacation"
# → AI translates to: ext:jpg;png;heic "sunset" vacation

deepfinder "PDF reports modified this month"
# → AI translates to: ext:pdf dm:thismonth report
```

If translation fails (rate limit, network error, or no key configured), your input is passed through unchanged as a plain text search.

The translation works in the REPL too:

```
> show me all spreadsheets from Q1
# AI translates and returns results
```

---

## Understand Match Results (`:explain`)

The `:explain` command tells you why a specific result matched your query — no AI needed, purely rule-based:

```
> :explain 1
Match type: exact
Position: 0
Reason: Exact match: filename equals 'budget_2026.xlsx'
```

Match types include `exa` (exact), `pre` (prefix), `sub` (substring), and `pin` (pinyin). This works with or without AI features enabled.

---

## Verify What's Sent (`:data_preview`)

The `:data_preview` command shows exactly what data would be sent to your AI provider before any request is made:

```
> :data_preview
=== AI Data Preview ===
Provider: deepseek
Model: deepseek-chat
System prompt: You are a search assistant...
Context: query="report", resultCount=42, fileNames=["report_q1.pdf", "report_q2.pdf", ...]
```

This transparency tool shows the prompt structure, context, and system message. Use it to verify privacy before enabling cloud AI. **File contents are never included** — only metadata (names, sizes, dates, extensions, capped at 20 result names).

---

## Privacy: What Goes to the Cloud

Cloud AI features are **opt-in only**. Nothing is sent unless you configure an API key and trigger AI translation.

**What IS sent to cloud providers:**

| Data sent | Capped at |
|-----------|-----------|
| Your search query text | — |
| File metadata (names only) | 20 names |
| Extensions | 20 extensions |
| AI system prompts | — |

**What is NEVER sent:**

- File contents
- Full file paths
- Personal documents, images, or any file data
- Clipboard contents

**What runs entirely on-device (no cloud):**

| Feature | Technology | Privacy |
|---------|-----------|---------|
| Vision tagging | Apple Vision (`VNClassifyImageRequest`) | Neural Engine. No image leaves the device. |
| Speech input | Apple Speech (`SFSpeechRecognizer`) | On-device. Audio not stored. |
| Clipboard search | `NSPasteboard` | Local read. On-demand. Never auto-searches. |
| Match explanation | Rule-based | No network calls. |

---

## Speech Input

Voice search uses Apple's on-device speech recognition. Two permissions are required:

1. **Speech Recognition** (SFSpeechRecognizer)
2. **Microphone** (AVAudioApplication)

Both are requested on first use with a unified authorization flow. Speech input streams partial results in real-time and finalizes when you stop speaking. No audio is stored or transmitted.

Speech input is available in the GUI via the microphone button in the search panel. CLI speech support is on the roadmap.

---

## Vision Tagging

Image files (JPG, PNG, HEIC, GIF) discovered during indexing are analyzed locally using `VNClassifyImageRequest`. Tags like "sunset", "beach", "mountain" are added to the media metadata index automatically.

Vision tagging runs in the background with bounded concurrency (max 4 concurrent analyses) to avoid saturating the Neural Engine. You can then search using these tags:

```bash
deepfinder "tag:sunset"                    # Files tagged as sunset
deepfinder "tag:beach ext:jpg dm:thisyear" # Beach photos from this year
```

No configuration required — vision tagging runs automatically as part of indexing when new images are discovered.

---

## File Operations with Undo

AI can translate natural language commands into file operations (move, copy, rename):

```
> move all PDF reports to ~/Documents/Reports/
Preview:
  move /Users/nadav/Desktop/report_q1.pdf → /Users/nadav/Documents/Reports/report_q1.pdf
  move /Users/nadav/Desktop/report_q2.pdf → /Users/nadav/Documents/Reports/report_q2.pdf
Execute? [y/N] y
Moved 2 files.

> :undo
Undone: move 'report_q1.pdf' to '/Users/nadav/Documents/Reports/report_q1.pdf'
```

Operation history keeps the last 20 operations for undo. Supported operations: move, copy, rename. **Destructive operations (delete, remove) are blocked** — they must be done manually.

---

## Where to Go Next

| You want to... | Read this |
|---------------|-----------|
| Learn all search syntax | [Find Files](find-files.md) |
| Filter by size, date, type | [Filter Results](filter-results.md) |
| Use the REPL commands | [REPL Interaction](repl-interact.md) |
| Understand the privacy model | [Privacy Model](../explanation/privacy-model.md) |
| See the full AI design | [AI Tech Stack Design](../superpowers/specs/design/2026-06-01-ai-tech-stack-design.md) |
