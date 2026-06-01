# DeepFinder Integration Guide

How to integrate DeepFinder search into other tools, scripts, and automation workflows.

## Table of Contents

- [CLI Scripting](#cli-scripting)
- [HTTP API](#http-api)
- [URL Scheme (`deepfinder://`)](#url-scheme-deepfinder)
- [AppleScript](#applescript)
- [Shortcuts (App Intents)](#shortcuts-app-intents)

---

## CLI Scripting

DeepFinder CLI is designed for shell pipelines. Use `--json` for structured output, `--0` for null-delimited paths, and exit codes for control flow.

### Single-shot Search

```bash
# Basic search
deepfinder "report.pdf"

# JSON output (machine-readable)
deepfinder --json "*.swift"

# Null-delimited output (safe for filenames with spaces/newlines)
deepfinder --0 "photo" | while IFS= read -r -d '' path; do
    echo "Found: $path"
done

# Pagination
deepfinder --limit 10 --offset 20 "report"

# Sort by date (newest first)
deepfinder --sort date --reverse "report"
```

### xargs Patterns

```bash
# Open all matching files
deepfinder --0 "*.pdf" | xargs -0 open

# Move matching files to a directory
deepfinder --0 "screenshot*.png" | xargs -0 -I {} mv {} ~/Pictures/Screenshots/

# Delete matching files (use with caution)
deepfinder --0 "*.tmp" | xargs -0 rm

# Copy with progress
deepfinder --0 "*.mov" | xargs -0 -I {} cp {} ~/Videos/
```

### jq with --json

```bash
# Extract just file paths
deepfinder --json "report" | jq -r '.[].path'

# Filter by extension
deepfinder --json "report" | jq -r '.[] | select(.path | endswith(".pdf")) | .path'

# Count results
deepfinder --json "*.swift" | jq 'length'

# Format as table
deepfinder --json --verbose "report" | jq -r '["PATH","SCORE","MATCH"], (.[] | [.path, (.score|tostring), .matchType]) | @tsv' | column -t
```

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | Success -- results found |
| `1` | No results found |
| `2` | Daemon error (daemon not running or IPC failure) |
| `3` | Query error (invalid query syntax) |

```bash
# Conditional logic based on results
if deepfinder "config.json" > /dev/null 2>&1; then
    echo "Found config.json"
else
    echo "config.json not found (exit code $?)"
fi
```

### Daemon Management

```bash
# Ensure daemon is running before scripting
deepfinder daemon start

# Check daemon status
deepfinder daemon status

# Install auto-start on login
deepfinder install
```

---

## HTTP API

For integrations that prefer HTTP over CLI (web dashboards, Raycast/Alfred extensions, Electron apps), start the HTTP server:

```bash
deepfinder --serve --port 7654
```

Then call `http://localhost:7654` endpoints. See [API.md](API.md) for the full reference.

Quick examples:

```bash
# Search
curl -s "http://localhost:7654/search?q=report&limit=5" | jq '.results'

# Health check
curl -s http://localhost:7654/health

# Stats
curl -s http://localhost:7654/stats
```

### JavaScript / Browser

```javascript
// Fetch results from a dashboard widget
const results = await fetch("http://localhost:7654/search?q=report&limit=10")
  .then(r => r.json())
  .then(data => data.results.map(r => r.path));

// Check if daemon is running
const healthy = await fetch("http://localhost:7654/health")
  .then(r => r.json())
  .then(data => data.status === "ok");
```

### Alfred Workflow Script Filter

```bash
#!/bin/bash
# Alfred Script Filter — called with {query} from Alfred
curl -s "http://localhost:7654/search?q={query}&limit=20" | \
  jq '[.results[] | {title: .name, subtitle: .path, arg: .path}] | {items: .}'
```

### Raycast Extension

```typescript
// Raycast extension — search command
import fetch from "node-fetch";

export default async function search(query: string) {
  const res = await fetch(`http://localhost:7654/search?q=${encodeURIComponent(query)}&limit=20`);
  const data = await res.json() as { results: { path: string; name: string }[] };
  return data.results.map(r => ({ title: r.name, subtitle: r.path }));
}
```

---

## URL Scheme (`deepfinder://`)

DeepFinder registers the `deepfinder://` URL scheme for deep-linking from other applications. When a `deepfinder://` URL is opened, macOS routes it to the DeepFinder app.

### Format

```
deepfinder://search?q=<query>&limit=<n>&filter=<expr>
```

| Parameter | Required | Description |
|---|---|---|
| `q` | yes | Search query string (URL-encoded) |
| `limit` | no | Maximum results (positive integer) |
| `filter` | no | Filter expression (e.g. `ext:pdf`) |

### Examples

```
deepfinder://search?q=report
deepfinder://search?q=invoice&limit=50
deepfinder://search?q=photo&filter=ext:png
deepfinder://search?q=tax%20return&limit=20&filter=ext:pdf
```

### Opening from Terminal

```bash
open "deepfinder://search?q=report"
open "deepfinder://search?q=invoice&limit=10"
```

### Opening from Other Apps

Any macOS app can open a `deepfinder://` URL via `NSWorkspace`:

```swift
// Swift
let url = URL(string: "deepfinder://search?q=report")!
NSWorkspace.shared.open(url)
```

```javascript
// JavaScript for Automation (JXA)
ObjC.import('AppKit');
const url = $.NSURL.URLWithString('deepfinder://search?q=report');
$.NSWorkspace.sharedWorkspace.openURL(url);
```

### Registration

The URL scheme is registered via the app's `Info.plist` `CFBundleURLTypes` entry. macOS associates `deepfinder://` links with the DeepFinder app automatically on first launch.

---

## AppleScript

DeepFinder exposes a `search` command via its AppleScript dictionary (sdef). The command returns a list of matching file paths.

### Syntax

```applescript
tell application "DeepFinder" to search "query"
```

Returns: `list of string` -- absolute file paths matching the query.

### Examples

```applescript
-- Basic search
tell application "DeepFinder"
    set results to search "report.pdf"
end tell

-- Open first matching file
tell application "DeepFinder"
    set results to search "config.json"
    if (count of results) > 0 then
        set firstResult to item 1 of results
        -- Open in default application
        do shell script "open " & quoted form of firstResult
    end if
end tell

-- Loop through results
tell application "DeepFinder"
    set results to search "*.swift"
    repeat with filePath in results
        display dialog "Found: " & filePath
    end repeat
end tell

-- Search with count check
tell application "DeepFinder"
    set results to search "budget"
    set resultCount to count of results
    display notification (resultCount as string) & " results found" with title "DeepFinder"
end tell
```

### In Automator

1. Add a "Run AppleScript" action
2. Paste an AppleScript snippet using `tell application "DeepFinder" to search "..."` 
3. Use the returned paths in subsequent Automator actions (e.g., "Move Finder Items")

### Error Handling

When the daemon is unavailable, `search` returns an empty list. Scripts should check the result count:

```applescript
tell application "DeepFinder"
    set results to search "report"
    if results is {} then
        display dialog "No results found or DeepFinder daemon is not running." buttons {"OK"} default button 1
    end if
end tell
```

### Implementation Note

The AppleScript command is implemented by `DeepFinderSearchCommand` (an `NSScriptCommand` subclass). It extracts the direct parameter from the Apple Event and delegates to the daemon via IPC. Results are returned as an `NSArray` of `NSString` paths.

---

## Shortcuts (App Intents)

DeepFinder provides a `SearchFilesIntent` App Intent for use in Apple Shortcuts on macOS.

### Available Action

**Search Files** -- Searches for files by name and returns file paths.

| Parameter | Type | Required | Description |
|---|---|---|---|
| Query | String | yes | The search query |
| Limit | Integer | no | Maximum results (default: 20) |

**Returns**: List of file paths (strings).

### Shortcut Examples

**Open first matching file:**

1. Add "Search Files" action
2. Set Query to "budget"
3. Add "Open File" action
4. Set file to "Search Files result" (choose "First Item")

**Count matching files and notify:**

1. Add "Search Files" action
2. Set Query to "*.pdf"
3. Add "Count" action, set to "Search Files result"
4. Add "Show Notification" action with count

**Copy all matching paths:**

1. Add "Search Files" action
2. Set Query to "screenshot*"
3. Add "Combine Text" action, joining with newlines
4. Add "Copy to Clipboard" action

### In Siri

After creating a Shortcut with the "Search Files" action, you can invoke it via Siri on macOS. Example shortcut names: "Find my reports", "Open latest budget", "Show screenshots".

### Implementation Note

`SearchFilesIntent` conforms to the `AppIntent` protocol from the `AppIntents` framework. It is discovered automatically by the Shortcuts app. The intent communicates with the daemon via IPC to perform searches.

---

## Combining Integration Methods

### Shell Script calling AppleScript

```bash
#!/bin/bash
# Use AppleScript to search, then process results in bash
osascript -e 'tell application "DeepFinder" to search "*.log"' | while IFS=, read -r path; do
    wc -l "$path"
done
```

### Shortcut invoking URL Scheme

Create a Shortcut that:
1. Accepts text input
2. URL-encodes it
3. Opens `deepfinder://search?q=<encoded_text>`

### Automator + CLI

In Automator:
1. "Run Shell Script" action with `/bin/bash`
2. Run `deepfinder --0 "*.png"`
3. Pass results to "New Folder with Items" or other Finder actions
