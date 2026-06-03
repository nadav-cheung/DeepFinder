# Privacy Model

DeepFinder is **local-first by design**. Everything stays on your Mac unless you explicitly opt into cloud AI features.

## What Never Leaves Your Mac

| Data | Location | Notes |
|------|----------|-------|
| File names, paths, sizes, dates | Local daemon RAM + SQLite | Index database at `~/.deep-finder/cache/index.db` (permissions 600) |
| File contents | Never read unless content search | Only scanned on-demand during search, never stored |
| Search queries | Processed in-daemon | Not logged, not transmitted |
| Vision tags (image classification) | Apple Neural Engine | `VNClassifyImageRequest` — on-device only |
| Speech recognition | Apple SFSpeechRecognizer | On-device only, requires microphone permission |
| Clipboard contents | Local `NSPasteboard` | Read on-demand, never stored or transmitted |
| Configuration | `~/.deep-finder/settings.json` (permissions 600) | API keys in `~/.deep-finder/.env` (permissions 600, owner-only) |

## What Goes to the Cloud (Opt-in Only)

Cloud AI features are **completely optional**. They are only active when you:

1. Explicitly configure an API key (`deepseekApiKey` or `qwenApiKey`)
2. Use a natural language search query that triggers AI translation

When active, the following is sent to your chosen AI provider:

| Data sent | Example | Capped at |
|-----------|---------|-----------|
| Your search query text | "find large video files from last week" | — |
| File metadata (names only) | `["report_q1.pdf", "report_q2.pdf", ...]` | 20 names |
| Extensions | `["pdf", "xlsx", "docx"]` | 20 extensions |
| System prompt | "You are a search query translator..." | — |

**Never sent to cloud**:
- ❌ File contents
- ❌ Full file paths
- ❌ Any document, image, or media data
- ❌ Clipboard contents
- ❌ Personal information

## Verifying What's Sent

Use the `:data_preview` REPL command to see exactly what would be sent to your AI provider:

```
> :data_preview
=== AI Data Preview ===
Provider: deepseek
Model: deepseek-v4-flash
System prompt: You are a search assistant...
Context: query="report", resultCount=42, fileNames=["report_q1.pdf", ...]
```

This transparency tool lets you verify privacy before enabling cloud AI.

## Local AI Features

| Feature | Technology | Privacy |
|---------|-----------|---------|
| Vision tagging | Apple Vision (`VNClassifyImageRequest`) | On-device. Neural Engine. No image data leaves the device. |
| Speech input | Apple Speech (`SFSpeechRecognizer`) | On-device. Requires microphone permission. Audio not stored. |
| Clipboard search | `NSPasteboard` | Local read only. On-demand. Never auto-searches. |
| Match explanation | Rule-based | No network calls. Purely algorithmic. |

## Data Storage

| Path | Contents | Permissions |
|------|----------|-------------|
| `~/.deep-finder/settings.json` | User configuration | 600 (owner only) |
| `~/.deep-finder/.env` | API keys (permissions 600, owner-only) | 600 (owner only) |
| `~/.deep-finder/cache/index.db` | File metadata index (names, sizes, dates, paths) | 600 (owner only) |
| `~/.deep-finder/history` | REPL command history | 600 (owner only) |
| `~/.deep-finder/.env` | API keys (Anthropic, DeepSeek, Qwen, Gemini) | 600 (owner only) |

## Zero Telemetry

DeepFinder collects **zero analytics, zero crash reports, zero usage data**. There is no analytics framework, no network calls on startup, and no phone-home behavior. The only network traffic is:

1. **Homebrew/Sparkle**: Version check for updates (can be disabled)
2. **Cloud AI provider**: Only if you configure an API key and trigger AI translation

## Comparison

| | DeepFinder | Spotlight | Alfred | Raycast | Fenn |
|---|-----------|-----------|--------|---------|------|
| Index stored | Local only | Local only | Local only | Local only | Local only |
| Search queries | Local | Local + Siri Suggestions | Local | Local + Cloud (Pro) | Cloud |
| AI features | Opt-in cloud + local | Apple Intelligence (system) | N/A | Pro subscription required | Cloud required |
| Telemetry | **None** | Apple diagnostics | None | Usage analytics | Unknown |
| Open source | ✅ Verifiable | ❌ | ❌ | ❌ | ❌ |

---

*See [ADR-004: AI Privacy Boundary & FileMetadata Summary](../adr/ADR-004-ai-privacy-boundary-filemetadata-summary.md) for the privacy design decision.*
