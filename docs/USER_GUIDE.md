# DeepFinder User Guide

DeepFinder is a macOS file search tool -- fast, local, indexed. Think "Everything" for Mac. It indexes your entire file system so queries return results in under a millisecond.

**Platform**: macOS 26+ (Tahoe), Apple Silicon (M4+) only.
**Version**: 3.0

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [CLI Reference](#cli-reference)
3. [Search Syntax](#search-syntax)
4. [Metadata Filters](#metadata-filters)
5. [REPL Commands](#repl-commands)
6. [Daemon Management](#daemon-management)
7. [Configuration](#configuration)
8. [AI Features](#ai-features)
9. [GUI](#gui)
10. [HTTP API](#http-api)
11. [Examples](#examples)

---

## Quick Start

### Install

```bash
# Homebrew (recommended)
brew install nadav/deepfinder/deepfinder

# Or download the binary from GitHub Releases and place in PATH
```

### First Search

The daemon starts automatically on your first query:

```bash
deepfinder "vacation photo"
```

This auto-starts the background daemon, which indexes your files. The first run may take a moment while the index builds. Subsequent queries return instantly.

### Daemon Start / Stop

```bash
# Start the daemon manually
deepfinder daemon start

# Stop the daemon
deepfinder daemon stop

# Check daemon status
deepfinder daemon status
```

Output from `daemon status`:

```
Daemon running (PID 12345)
  Uptime: 2h 30m
  Index state: live
  Files indexed: 482391
  Memory: 342.1 MB
```

### Auto-Start on Login

```bash
deepfinder install   # Install LaunchAgent (starts on login)
deepfinder uninstall # Remove LaunchAgent
```

---

## CLI Reference

### Single-Shot Search

```bash
deepfinder "query"        # Basic search
deepfinder --json "query" # JSON output (for scripts)
deepfinder --0 "query"    # Null-byte separated paths (for xargs)
```

### Flags

| Flag | Description |
|------|-------------|
| `--json` | Output results as JSON (`[{"path":"...","name":"...","size":...,"modified":...}]`) |
| `--0` | Separate results by null bytes (`\0`) instead of newlines. Safe for paths with spaces -- pipe to `xargs -0`. |
| `--sort name\|size\|date` | Sort results by name, file size, or modification date. Default: relevance score. |
| `--limit N` | Return at most N results. Default: 1000. |
| `--offset N` | Skip the first N results. Useful for pagination. |
| `--reverse` | Reverse the sort order. Combine with `--sort` (e.g., `--sort size --reverse` for largest files first). |
| `--verbose` | Show additional debug information: match type, score, provider ID for each result. |
| `--help` | Show the help text and exit. |
| `--version` | Show the DeepFinder version and exit. |
| `--serve` | Start HTTP server mode (see [HTTP API](#http-api)). |
| `--port N` | Set the HTTP server port when using `--serve`. Default: 7654. |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success -- results found and displayed |
| 1 | No results found for the query |
| 2 | Daemon error -- daemon not running or unreachable |
| 3 | Query error -- invalid query syntax or parameter |

### Examples

```bash
# JSON output for scripting
deepfinder --json "budget 2026" | jq '.[] | .path'

# Pipe to xargs safely (paths with spaces)
deepfinder --0 "*.mp4" | xargs -0 -I {} mv {} ~/Videos/

# Get the 10 largest files
deepfinder --sort size --reverse --limit 10 ""

# Paginate: results 101-200
deepfinder --offset 100 --limit 100 "report"
```

---

## Search Syntax

DeepFinder's query parser supports plain text, boolean operators, wildcards, regex, and modifiers.

### Plain Text

Space-separated terms are ANDed. Matching is **case-insensitive** and **substring** -- `report` matches `Report.txt`, `sales_report.pdf`, `REPORT_FINAL.xlsx`.

```bash
deepfinder "quarterly report"   # Files with BOTH "quarterly" AND "report"
```

### Wildcards

Use `*` (any sequence) and `?` (single character):

```bash
deepfinder "*.pdf"              # All PDF files
deepfinder "report_??.txt"      # report_01.txt, report_ab.txt
deepfinder "*vacation*"         # Any file with "vacation" in the name
```

### Boolean Operators

| Operator | Symbol | Example |
|----------|--------|---------|
| AND | (space) | `report 2026` -- both terms must match |
| OR | `\|` | `report \| memo` -- either term matches |
| NOT | `!` | `report !draft` -- "report" but NOT "draft" |
| Grouping | `()` | `(report \| memo) 2026` -- AND with grouped OR |

```bash
deepfinder "(report | memo) !draft"  # Report or memo, but not drafts
deepfinder "budget !2025"            # Budget documents, excluding 2025
```

### Regular Expressions

Prefix with `regex:`:

```bash
deepfinder "regex:^report_\d{4}\.pdf"   # report_2026.pdf, report_2025.pdf
deepfinder "regex:\.[a-z]{2,4}$"        # Files with 2-4 char extensions
```

### Path Qualifiers

Restrict to a specific directory using **backslash-space** (`\ `):

```bash
deepfinder "Projects\ report"    # "report" anywhere, but only in paths containing "Projects"
deepfinder "src\ *.swift"        # Swift files under directories named "src"
```

The word before `\ ` is matched against path components (directory names). The rest is the regular query.

### Modifiers

Modifiers are `key:value` pairs that apply metadata filters:

```bash
deepfinder "ext:pdf report"           # PDF files containing "report"
deepfinder "size:>10mb *.mp4"         # MP4 files larger than 10 MB
deepfinder "dm:today report"          # Reports modified today
deepfinder "file: budget"             # Only files (not folders) matching "budget"
deepfinder "folder: project"          # Only folders matching "project"
deepfinder "case:sensitive README"    # Case-sensitive match for "README"
```

See [Metadata Filters](#metadata-filters) for the complete modifier reference.

### Escaping Special Characters

Escape operators with a backslash:

```bash
deepfinder "special\!file"     # Literal "special!file"
deepfinder "a\|b"              # Literal "a|b"
deepfinder "\(note\)"          # Literal "(note)"
```

---

## Metadata Filters

### Size (`size:`)

Filter by file size in bytes. Supports human-readable units: `b`, `kb`, `mb`, `gb`, `tb`.

| Syntax | Meaning |
|--------|---------|
| `size:>10mb` | Larger than 10 megabytes |
| `size:<1gb` | Smaller than 1 gigabyte |
| `size:>=1kb` | At least 1 kilobyte |
| `size:<=500mb` | At most 500 megabytes |
| `size:100kb..1mb` | Between 100 KB and 1 MB |

```bash
deepfinder "size:>1gb *.mkv"              # MKV files over 1 GB
deepfinder "size:10mb..100mb *.pdf"       # PDFs between 10 MB and 100 MB
deepfinder "size:<1kb"                    # Files smaller than 1 KB
```

### Date Modified (`dm:`)

Filter by modification date:

| Value | Meaning |
|-------|---------|
| `dm:today` | Modified today |
| `dm:yesterday` | Modified yesterday |
| `dm:thisweek` | Modified this week (Monday to now) |
| `dm:thismonth` | Modified this month |
| `dm:thisyear` | Modified this year |
| `dm:2026-01-01..2026-05-31` | Modified within a date range |

```bash
deepfinder "dm:today *.log"               # Log files modified today
deepfinder "dm:thisweek report"           # Reports modified this week
deepfinder "dm:2026-01-01..2026-03-31"    # All files from Q1 2026
```

### Extension (`ext:`)

Filter by file extension. Multiple extensions separated by `;`:

```bash
deepfinder "ext:pdf"                      # PDF files
deepfinder "ext:jpg;png;heic"             # Common image formats
deepfinder "ext:mp4;mkv;mov"             # Video files
```

### File Type (`file:`, `folder:`)

```bash
deepfinder "file: budget"                 # Files only (no directories)
deepfinder "folder: project"              # Directories only
```

### Case Sensitivity (`case:`)

```bash
deepfinder "case:sensitive README"        # Exactly "README" (not "readme")
deepfinder "case:insensitive README"      # Explicit case-insensitive (default)
```

### Path Depth (`depth:`)

Filter directories by how many levels deep they are from root:

```bash
deepfinder "depth:<=3 folder:"            # Folders at most 3 levels deep
deepfinder "depth:>=5"                    # Files at least 5 levels deep
```

### Numeric Metadata Filters

For media files, these metadata filters support the same comparison operators as `size:` (`>`, `<`, `>=`, `<=`, `range`):

| Key | Applies to | Example |
|-----|-----------|---------|
| `width:` | Image/video width in pixels | `width:>=3840` (4K+ width) |
| `height:` | Image/video height in pixels | `height:>1080` |
| `duration:` | Audio/video duration in seconds | `duration:>300` (longer than 5 min) |
| `pages:` or `pagecount:` | Document page count | `pages:>=50` |
| `fps:` | Video frames per second | `fps:>=60` |
| `bitrate:` | Audio/video bitrate in kbps | `bitrate:>320` |

```bash
deepfinder "width:>=3840 ext:jpg"          # High-res JPEG images
deepfinder "duration:60..300 ext:mp4"      # Videos between 1 and 5 minutes
deepfinder "pages:>100 ext:pdf"            # PDFs with more than 100 pages
```

### Text Metadata Filters

For media files with embedded tags:

| Key | Applies to | Example |
|-----|-----------|---------|
| `artist:` | Music artist | `artist:"The Beatles"` |
| `album:` | Music album name | `album:"Abbey Road"` |
| `title:` | Track/file title | `title:"Bohemian Rhapsody"` |
| `genre:` | Music genre | `genre:rock` |
| `codec:` | Audio/video codec | `codec:h264` |

```bash
deepfinder "artist:mozart ext:flac"        # Mozart tracks in FLAC
deepfinder "genre:jazz ext:mp3"            # Jazz MP3s
deepfinder "codec:hevc ext:mp4"            # HEVC-encoded videos
```

---

## REPL Commands

Start the interactive REPL by running `deepfinder` without arguments:

```bash
deepfinder
> _
```

Type a query directly, or prefix commands with `:`.

| Command | Alias | Description |
|---------|-------|-------------|
| `:help` | `:h` | Show all available commands |
| `:quit` | `:q` | Exit the REPL (Ctrl+D also works) |
| `:stats` | | Show index statistics: file count, index state, memory usage |
| `:daemon` | | Show daemon status: PID, uptime, index state, connections |
| `:open N` | | Open result N with the default application (1-based index) |
| `:reveal N` | | Reveal result N in Finder |
| `:explain N` | | Show why result N matched (match type, position, reasoning) |
| `:config KEY [VALUE]` | | Get or set a configuration key |
| `:data_preview` | `:dataPreview` | Show what data would be sent to AI providers (privacy transparency) |
| `:undo` | | Undo the last file operation (move/copy/rename) |

### Using the REPL

```
> vacation photo
1. /Users/nadav/Pictures/2026/vacation_beach.jpg    2.4 MB   exa  2026-03-15
2. /Users/nadav/Pictures/2026/vacation_hotel.jpg    1.8 MB   exa  2026-03-16
3. /Users/nadav/Documents/vacation_plan.md           12 KB    sub  2026-02-28
3 results

> :open 1
# Opens vacation_beach.jpg in Preview

> :explain 3
Match type: substring
Position: 0
Reason: Substring match: filename contains 'vacation'

> ext:jpg dm:thisweek
1. /Users/nadav/Documents/screenshot_20260531.jpg    856 KB   exa  2026-05-31
1 result
```

### History

The REPL saves command history to `~/.deep-finder/history`. Up to 1000 entries are retained. Consecutive duplicates are suppressed. Press Up/Down to navigate history.

---

## Daemon Management

The DeepFinder daemon runs in the background, holding the entire file index in memory for sub-millisecond queries.

### Subcommands

```bash
deepfinder daemon start      # Start the daemon if not running
deepfinder daemon stop       # Stop the daemon (sends SIGTERM)
deepfinder daemon restart    # Stop then start
deepfinder daemon status     # Show PID, uptime, index state, file count, memory
```

### Lifecycle

- **Auto-start**: When you run `deepfinder "query"` and the daemon is not running, it starts automatically.
- **PID file**: `~/.deep-finder/daemon.pid` -- tracks the running process.
- **Socket**: `~/.deep-finder/ipc.sock` -- Unix domain socket for IPC.
- **Shutdown**: `daemon stop` sends SIGTERM. The daemon flushes the SQLite index and removes the socket before exiting. If it does not exit within 5 seconds, use `kill -9 <PID>`.
- **Crash recovery**: Stale PID and socket files are cleaned up on the next `daemon start`.

### LaunchAgent

Install a LaunchAgent to start the daemon automatically on login:

```bash
deepfinder install           # Install ~/Library/LaunchAgents/com.nadav.deepfinder.plist
deepfinder uninstall         # Remove the LaunchAgent plist
```

---

## Configuration

Configuration is stored as JSON at `~/.deep-finder/config.json` (permissions 600, owner-only). Manage it via the `config` subcommand.

### Commands

```bash
deepfinder config get excludedPaths        # Get a single config value
deepfinder config set maxResults 500       # Set a config value
deepfinder config list                     # List all config keys and values
deepfinder config reset                    # Reset to defaults (prompts for confirmation)
```

### Config Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `excludedPaths` | `[String]` | `["/System", "/Library"]` | Paths excluded from indexing |
| `excludedVolumes` | `[String]` | `[]` | Volume mount paths excluded (e.g., Time Machine disks) |
| `indexBatchSize` | `Int` | `100` | Records per SQLite batch write |
| `maxResults` | `Int` | `1000` | Maximum results per query |
| `configVersion` | `Int` | `1` | Schema version for migrations |

### Examples

```bash
# Exclude a custom path from indexing
deepfinder config set excludedPaths '["/System","/Library","/Users/nadav/Downloads"]'

# Increase the result limit
deepfinder config set maxResults 5000

# Reset everything to defaults
deepfinder config reset
```

---

## AI Features

DeepFinder v3.0 adds AI-powered semantic search, natural language understanding, and local intelligence.

### Overview

| Feature | Type | Requires |
|---------|------|----------|
| Natural language to search syntax | Cloud | API key (DeepSeek or Qwen) |
| Semantic search suggestions | Cloud | API key |
| Result summarization | Cloud | API key |
| Intent analysis | Cloud | API key |
| Vision tagging (image classification) | **Local** | None (Apple Neural Engine) |
| Speech input (voice search) | **Local** | Microphone permission |
| Clipboard search | **Local** | None |
| File operations (move/copy/rename via NL) | Cloud | API key |

### Providers

Two OpenAI-compatible providers are supported:

| Provider | Model | Endpoint |
|----------|-------|----------|
| **DeepSeek** | `deepseek-v4-flash` | `api.deepseek.com` |
| **Qwen** (Tongyi Qianwen) | `qwen-plus` | `dashscope.aliyuncs.com` |

To enable AI features, set your API key:

```bash
deepfinder config set deepseekApiKey "sk-..."
# or
deepfinder config set qwenApiKey "sk-..."
```

### Natural Language Search

When an AI provider is configured, you can type queries in plain English:

```
> find large video files from last week
# AI translates to: ext:mp4;mov;mkv dm:lastweek size:>100mb

> photos of sunsets from my vacation
# AI translates to: ext:jpg;png;heic "sunset" vacation
```

The `NLSearchTranslator` automatically detects whether input is already search syntax (skipping translation) or natural language (invoking the AI provider). If translation fails (rate limit, network error), the input is passed through unchanged as a plain text search.

### Match Explanation (`:explain N`)

Understand why a result matched -- no AI needed, purely rule-based:

```
> :explain 1
Match type: exact
Position: 0
Reason: Exact match: filename equals 'budget_2026.xlsx'
```

### Data Preview (`:data_preview`)

See exactly what data would be sent to AI providers. This transparency tool shows the prompt structure, context (file metadata only -- never contents), and system message. Use it to verify privacy before enabling cloud AI.

```
> :data_preview
=== AI Data Preview ===
Provider: deepseek
Model: deepseek-v4-flash
System prompt: You are a search assistant...
Context: query="report", resultCount=42, fileNames=["report_q1.pdf", "report_q2.pdf", ...]
```

### Privacy Model

**What IS sent to cloud providers:**
- Your search query text
- File metadata: names, sizes, dates, extensions (capped at 20 result names)
- AI system prompts

**What is NEVER sent:**
- File contents
- Full file paths
- Personal documents, images, or any file data
- Clipboard contents

**What runs locally:**
- Vision tagging: Uses Apple's Vision framework on the Neural Engine. No image data leaves the device.
- Speech recognition: Uses Apple's SFSpeechRecognizer. On-device processing. Requires microphone permission.
- Clipboard search: Reads NSPasteboard text locally. No clipboard content is logged or stored beyond the session. Requires explicit user action -- never auto-searches.
- Match explanation: Rule-based, no network calls.

### Speech Input

Voice search uses Apple's on-device speech recognition. Two permissions are required:
1. **Speech Recognition** (SFSpeechRecognizer)
2. **Microphone** (AVAudioApplication)

Both are requested on first use with a unified authorization flow. Speech input streams partial results in real-time and finalizes when you stop speaking.

### Vision Tagging

Image files (JPG, PNG, HEIC, GIF) discovered during indexing are analyzed locally using `VNClassifyImageRequest`. Tags like "sunset", "beach", "mountain" are added to the media metadata index. This runs in the background with bounded concurrency (max 4 concurrent analyses) to avoid saturating the Neural Engine.

### File Operations with Undo

AI can translate natural language commands into file operations:

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

Operation history keeps the last 20 operations for undo. Operations include move, copy, and rename. Destructive operations (delete, remove) are blocked -- they must be done manually.

---

## GUI

DeepFinder v2.0 added a native macOS GUI accessible via global hotkey.

### Launch

The GUI is a **menu bar app** (LSUIElement -- no Dock icon). It appears as an icon in the menu bar. Click the icon or press the global hotkey.

### Global Hotkey

**Ctrl+Cmd+K** (Control+Command+K) opens the search panel from anywhere. The hotkey requires Accessibility permission (prompted on first use). If the hotkey registration fails (e.g., conflict with another app), it retries with exponential backoff.

### Search Panel

The search panel is a floating **NSPanel** with **Liquid Glass** effect (`.glassEffect()`). Type your query and results appear as you type.

The panel features an **Apple Intelligence glow** -- a rotating angular gradient (teal, violet, coral, amber) that animates at 60fps while the panel is active.

### Result Rows

Each result row shows:
- **File icon** (16x16, cached by extension)
- **Filename** with query match highlighting (bold matching characters)
- **Shortened path** (parent directory, truncated with `...` for long paths)
- **Match badge** (exa=exact, pre=prefix, sub=substring, pin=pinyin)
- **Size** (human-readable: KB, MB, GB, TB)
- **Date** (modification date)

### Interactions

| Action | How |
|--------|-----|
| Open file | Double-click or Enter |
| Reveal in Finder | Cmd+Enter |
| Quick Look preview | Space (QLPreviewPanel with up/down navigation) |
| Context menu | Right-click: Open, Reveal in Finder, Copy Path, Get Info |
| Drag to Finder/Terminal | Drag a result row as a file URL |

### Context Menu

Right-click any result for:
- **Open** -- open with default application
- **Reveal in Finder** -- show in Finder window
- **Copy Path** -- copy the full POSIX path to clipboard
- **Get Info** -- open Finder's Get Info panel for the file

### Drag Support

Drag a result row directly to:
- **Finder** -- to copy or move the file
- **Terminal** -- to paste the full path
- **Any app** that accepts file URL drops

---

## HTTP API

DeepFinder can run as a local HTTP server for integration with scripts, web apps, and automation tools.

### Starting the Server

```bash
deepfinder --serve                # Start on default port 7654
deepfinder --serve --port 8080    # Start on custom port
```

The server runs until interrupted with Ctrl+C. It binds to `localhost` only -- not accessible from other machines.

### Endpoints

#### `GET /health`

Returns server status.

```bash
curl http://localhost:7654/health
```

```json
{"status":"ok"}
```

#### `GET /search`

Search the index.

**Parameters:**

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `q` | string | `""` | Search query (supports all search syntax) |
| `limit` | int | `100` | Maximum results to return |
| `offset` | int | `0` | Skip this many results |

```bash
curl "http://localhost:7654/search?q=report&limit=5"
```

```json
{
  "query": "report",
  "results": [
    {"path": "/Users/nadav/Documents/report_q1.pdf", "name": "report_q1.pdf"},
    {"path": "/Users/nadav/Documents/report_q2.pdf", "name": "report_q2.pdf"}
  ],
  "total": 2,
  "offset": 0,
  "limit": 5
}
```

#### `GET /stats`

Returns daemon and index statistics.

```bash
curl http://localhost:7654/stats
```

```json
{
  "totalFiles": 482391,
  "indexState": "live",
  "uptimeSeconds": 9000.5,
  "memoryUsageMB": 342.1
}
```

### Common curl Recipes

```bash
# Search with all search syntax
curl "http://localhost:7654/search?q=ext:pdf%20dm:today"

# Paginate results (get page 2)
curl "http://localhost:7654/search?q=*.swift&offset=100&limit=100"

# Health check for monitoring
curl -s http://localhost:7654/health | jq .

# Count total files indexed
curl -s http://localhost:7654/stats | jq .totalFiles

# Find large files
curl "http://localhost:7654/search?q=size:>1gb&limit=20" | jq '.results[] | .path'
```

### Error Responses

| Status | Meaning |
|--------|---------|
| 200 | Success |
| 400 | Bad request (malformed HTTP) |
| 404 | Unknown endpoint |
| 405 | Method not allowed (only GET is supported) |

---

## Examples

### Finding Files

```bash
# All PDFs modified this week
deepfinder "ext:pdf dm:thisweek"

# Files with "budget" in the name, larger than 1 MB
deepfinder "budget size:>1mb"

# Swift files in a src directory, excluding test files
deepfinder "src\ *.swift !test"

# Images from a specific date range
deepfinder "ext:jpg;png dm:2026-05-01..2026-05-31"

# Files matching a naming pattern
deepfinder "regex:^IMG_\d{4}\.jpg"

# Find empty directories
deepfinder "folder: size:<1kb"
```

### Media Management

```bash
# High-res wallpapers
deepfinder "width:>=2560 ext:jpg;png"

# Long videos (over 30 minutes)
deepfinder "duration:>1800 ext:mp4;mkv;mov"

# Music by a specific artist in lossless format
deepfinder "artist:mozart ext:flac;alac"

# 60fps video files
deepfinder "fps:>=60 ext:mp4"

# Large documents for review
deepfinder "pages:>50 ext:pdf"
```

### Scripting

```bash
# Archive all log files from today
deepfinder --0 "dm:today ext:log" | xargs -0 tar -czf logs_$(date +%Y%m%d).tar.gz

# Count files by extension
deepfinder --json "ext:swift" | jq 'length'

# Find and move old files
deepfinder --0 'dm:<2025-01-01 ext:zip' | xargs -0 -I {} mv {} ~/Archive/

# Generate a file listing for inventory
deepfinder --json 'size:>100mb' > large_files_$(date +%Y%m%d).json
```

### REPL Workflow

```
> dm:today
1. /Users/nadav/Desktop/screenshot.png    1.2 MB   exa  2026-05-31
2. /Users/nadav/Documents/notes.md         4.5 KB   sub  2026-05-31
2 results

> :open 2
# Opens notes.md in default editor

> ext:pdf report
1. /Users/nadav/Documents/report_q1.pdf    2.1 MB   sub  2026-04-15
2. /Users/nadav/Documents/report_q2.pdf    1.8 MB   sub  2026-05-20
2 results

> :explain 1
Match type: substring
Position: 0
Reason: Substring match: filename contains 'report'

> :stats
Index state: live
Files indexed: 482391
Memory: 342.1 MB

> :quit
Goodbye.
```

### HTTP API Automation

```bash
#!/bin/bash
# Check if DeepFinder daemon is healthy before proceeding
HEALTH=$(curl -s http://localhost:7654/health)
if echo "$HEALTH" | jq -e '.status == "ok"' > /dev/null; then
    echo "Daemon is healthy"
else
    echo "Daemon is not responding"
    exit 1
fi

# Search for files matching criteria
curl -s "http://localhost:7654/search?q=dm:today%20ext:log&limit=50" | jq '.results[] | .path'
```

### AI-Powered Search

```
> find all presentation files from this quarter
# AI translates to: ext:pptx;key;pdf dm:2026-04-01..2026-06-30

> large images i downloaded recently
# AI translates to: ext:jpg;png;heic size:>10mb dm:thisweek

> music files with high bitrate
# AI translates to: ext:mp3;flac bitrate:>=320
```

---

## File Paths Reference

| Path | Purpose |
|------|---------|
| `~/.deep-finder/` | Config and data directory |
| `~/.deep-finder/config.json` | Daemon configuration (600 permissions) |
| `~/.deep-finder/daemon.pid` | Running daemon PID |
| `~/.deep-finder/ipc.sock` | Unix domain socket for IPC |
| `~/.deep-finder/index.db` | SQLite WAL index database (600 permissions) |
| `~/.deep-finder/history` | REPL command history |
| `~/Library/LaunchAgents/com.nadav.deepfinder.plist` | LaunchAgent plist |

---

## Tips

- **Speed**: The daemon holds the entire index in RAM. Queries return in under a millisecond. No debounce needed -- results are instant.
- **Pinyin**: Chinese filenames are searchable by pinyin. Typing `baogao` finds files named `报告.pdf`.
- **Unicode**: All filenames are NFC-normalized. Queries are normalized the same way. Accented and unaccented forms work interchangeably.
- **Volumes**: External and network volumes are indexed by default. They are removed from the index on unmount. Exclude specific volumes via `excludedVolumes` config.
- **Piped Output**: When stdout is not a terminal (piped to another command), ANSI colors are automatically disabled. Use `--json` or `--0` for reliable script output.
- **Full Disk Access**: DeepFinder needs Full Disk Access to index `~/Documents`, `~/Desktop`, `~/Downloads`, and other protected directories. Without it, these paths are silently skipped. Grant it in System Settings > Privacy & Security > Full Disk Access.
- **Not Sandboxable**: DeepFinder requires Full Disk Access and cannot be distributed through the Mac App Store. It is distributed via Homebrew and GitHub Releases.
