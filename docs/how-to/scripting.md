# Scripting & Automation

## You want to use DeepFinder in scripts

DeepFinder is designed for the command line. Every result can be piped, parsed, and composed with standard Unix tools. This guide covers the three scripting interfaces -- CLI flags for structured output, exit codes for control flow, and the HTTP API for integration with web apps and automation platforms.

---

## Choosing the Right Output Mode

| You want to... | Use |
|---------------|-----|
| Parse results field by field in a script | `--json` |
| Pipe file paths to another command (safe with spaces) | `--0` |
| See debug info alongside results | `--verbose` |
| Integrate from Python, JS, or a web app | [HTTP API](#http-api) |

> **Terminal output**: DeepFinder uses ANSI escape codes for colors and progress bars in the terminal. When stdout is piped (e.g., `deepfinder "query" | grep ...`) or redirected to a file, ANSI codes are automatically disabled. You do not need `--no-color` or similar flags -- it is handled transparently.

---

## JSON Output (`--json`)

`--json` writes a JSON array of result objects to stdout. Every field is typed and ready for `jq`.

```bash
deepfinder --json "report 2026"
```

A single result looks like this:

```json
{
  "path": "/Users/nadav/Documents/report_q1.pdf",
  "name": "report_q1.pdf",
  "size": 245760,
  "modified": "2026-01-15T10:30:00Z",
  "isDirectory": false,
  "matchType": "substring",
  "score": 0.87
}
```

### jq Recipes

```bash
# Extract just the paths
deepfinder --json "budget" | jq -r '.[].path'

# List filenames only
deepfinder --json "*.swift" | jq -r '.[].name'

# Find the largest match
deepfinder --json "*.mp4" | jq 'max_by(.size)'

# Count results
deepfinder --json "ext:pdf" | jq 'length'

# Filter by size within results (files over 10 MB)
deepfinder --json "report" | jq '.[] | select(.size > 10485760)'

# Build a CSV
deepfinder --json --limit 100 "" \
  | jq -r '["name","size","modified"], (.[] | [.name, .size, .modified]) | @csv' \
  > files.csv

# Open the newest match
deepfinder --json "screenshot *.png" \
  | jq -r 'max_by(.modified).path' \
  | xargs open
```

---

## Null-Byte Output (`--0`)

`--0` separates results by null bytes (`\0`) instead of newlines. This is the safe way to pipe file paths -- newlines and spaces in filenames cannot break it.

```bash
# Move all MP4 files to ~/Videos (safe with any filename)
deepfinder --0 "*.mp4" | xargs -0 -I {} mv {} ~/Videos/

# Delete all .DS_Store files
deepfinder --0 ".DS_Store" | xargs -0 rm

# Count lines in all Markdown files
deepfinder --0 "*.md" | xargs -0 wc -l

# Open every PDF modified today
deepfinder --0 "ext:pdf dm:today" | xargs -0 open
```

> Use `--0` whenever you pipe to `xargs`. It is always correct. `--json` + `jq -r` is an alternative when you need more control over which field to extract.

---

## Sorting, Pagination, and Volume Control

### Sorting (`--sort`)

```bash
# Largest files first
deepfinder --sort size --reverse --limit 20 ""

# Newest files first
deepfinder --sort date --reverse --limit 20 ""

# Alphabetical by name
deepfinder --sort name --limit 50 "ext:pdf"
```

### Pagination (`--limit`, `--offset`)

```bash
# First page (results 1-100)
deepfinder --limit 100 --offset 0 "ext:swift"

# Second page (results 101-200)
deepfinder --limit 100 --offset 100 "ext:swift"

# Iterate all results in a script
OFFSET=0
while true; do
  RESULTS=$(deepfinder --json --limit 100 --offset "$OFFSET" "ext:log")
  COUNT=$(echo "$RESULTS" | jq 'length')
  if [ "$COUNT" -eq 0 ]; then break; fi
  echo "$RESULTS" | jq -r '.[].path'
  OFFSET=$((OFFSET + 100))
done
```

---

## Exit Codes

DeepFinder uses specific exit codes. Check `$?` in your scripts to decide what to do next.

| Code | Meaning |
|------|---------|
| `0` | Success -- results found |
| `1` | No results found for the query |
| `2` | Daemon error -- daemon not running or unreachable |
| `3` | Query error -- invalid syntax or parameter |

### Conditional Logic

```bash
# Exit early if a required file is missing
if ! deepfinder "config.production.json" > /dev/null 2>&1; then
  echo "ERROR: config.production.json not found" >&2
  exit 1
fi

# Branch on result count
RESULTS=$(deepfinder --json "*.log")
if [ "$(echo "$RESULTS" | jq 'length')" -gt 50 ]; then
  echo "Warning: over 50 log files found" >&2
fi

# Handle daemon errors gracefully
deepfinder "report" > /dev/null 2>&1
case $? in
  0) echo "Results found" ;;
  1) echo "No results" ;;
  2) echo "Daemon is not running -- start it with: deepfinder daemon start" ;;
  3) echo "Invalid query syntax" ;;
esac
```

---

## HTTP API

Run DeepFinder as a local HTTP server for integration with languages that do not shell out easily (Python, JavaScript, Ruby), or with web apps and automation platforms.

### Starting the Server

```bash
deepfinder --serve                 # Default port 7654
deepfinder --serve --port 8080     # Custom port
```

The server binds to `localhost` only -- it is never accessible from other machines. Run it in the background with `&` or under `launchd`.

### Endpoints

#### `GET /health`

Check whether the server is running and the daemon is reachable.

```bash
curl -s http://localhost:7654/health
```

```json
{"status":"ok"}
```

#### `GET /search`

Search the index. Accepts the full search syntax.

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `q` | string | `""` | Search query (full syntax: wildcards, boolean, regex, modifiers) |
| `limit` | int | `100` | Maximum results to return |
| `offset` | int | `0` | Skip this many results |

```bash
curl -s "http://localhost:7654/search?q=report&limit=5"
```

```json
{
  "query": "report",
  "results": [
    {"path": "/Users/nadav/Documents/report_q1.pdf", "name": "report_q1.pdf", "size": 245760},
    {"path": "/Users/nadav/Documents/report_q2.pdf", "name": "report_q2.pdf", "size": 183500}
  ],
  "total": 42,
  "offset": 0,
  "limit": 5
}
```

#### `GET /stats`

Index and daemon statistics.

```bash
curl -s http://localhost:7654/stats
```

```json
{
  "totalFiles": 482391,
  "indexState": "live",
  "uptimeSeconds": 9000.5,
  "memoryUsageMB": 342.1
}
```

### curl Recipes

```bash
# Health check for monitoring scripts
curl -sf http://localhost:7654/health || echo "DeepFinder down" >&2

# Count total indexed files
curl -s http://localhost:7654/stats | jq .totalFiles

# Search with URL-encoded query syntax
curl -s "http://localhost:7654/search?q=ext%3Apdf%20dm%3Atoday" | jq '.results[] | .path'

# Find the 10 largest files
curl -s "http://localhost:7654/search?q=size%3A%3E1gb&limit=10" | jq '.results'

# Paginate: get page 3 (results 201-300)
curl -s "http://localhost:7654/search?q=*.swift&offset=200&limit=100" | jq '.results[] | .name'
```

### Error Responses

| Status | Meaning |
|--------|---------|
| 200 | Success |
| 400 | Bad request (malformed HTTP) |
| 404 | Unknown endpoint |
| 405 | Method not allowed (only GET is supported) |

### Python Example

```python
import urllib.request
import json

def deepfinder_search(query, limit=100):
    """Search DeepFinder via the HTTP API."""
    url = f"http://localhost:7654/search?q={urllib.parse.quote(query)}&limit={limit}"
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())

results = deepfinder_search("ext:pdf dm:thisweek", limit=20)
for r in results["results"]:
    print(f"{r['name']}  ({r['path']})")

# Health check
def is_daemon_alive():
    try:
        with urllib.request.urlopen("http://localhost:7654/health") as resp:
            return json.loads(resp.read())["status"] == "ok"
    except Exception:
        return False
```

---

## Practical Examples

### Archive Today's Log Files

```bash
#!/bin/bash
# archive-logs.sh -- zip all log files modified today

ARCHIVE="logs-$(date +%Y-%m-%d).tar.gz"
FILES=$(deepfinder --0 "ext:log dm:today")

if [ -z "$FILES" ]; then
  echo "No log files from today."
  exit 0
fi

echo "$FILES" | xargs -0 tar -czf "$ARCHIVE"
echo "Archived to $ARCHIVE"
```

### Count Files by Extension

```bash
#!/bin/bash
# count-by-ext.sh -- count files grouped by extension

for ext in pdf swift md png jpg mp4 log; do
  count=$(deepfinder --json "ext:$ext" | jq 'length')
  printf "%-6s %s\n" "$ext:" "$count"
done
```

Sample output:
```
pdf:   1,247
swift: 382
md:    156
png:   4,201
jpg:   8,933
mp4:   215
log:   73
```

### Find and Move Old Files

```bash
#!/bin/bash
# archive-old.sh -- move files not touched in over a year to an archive folder

ARCHIVE_DIR="$HOME/Archive/$(date +%Y)"
mkdir -p "$ARCHIVE_DIR"

# Files last modified before 2025
deepfinder --0 "dm:..2025-01-01" | while IFS= read -r -d '' file; do
  # Preserve directory structure under the archive root
  rel="${file#$HOME/}"
  dest="$ARCHIVE_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  mv "$file" "$dest"
  echo "Archived: $rel"
done
```

### Watch for New Large Files (cron)

```bash
#!/bin/bash
# monitor-large.sh -- alert when files over 500 MB appear
# Run this from cron every hour: 0 * * * * /path/to/monitor-large.sh

THRESHOLD_MB=500
RESULTS=$(deepfinder --json "size:>${THRESHOLD_MB}mb dm:today")

if [ "$(echo "$RESULTS" | jq 'length')" -gt 0 ]; then
  echo "$RESULTS" | jq -r '.[] | "\(.name)  (\(.size / 1048576 | floor) MB)"' \
    | mail -s "Large files detected today" you@example.com
fi
```

### Build a Custom Alfred-Style Launcher with fzf

```bash
#!/bin/bash
# df-fzf.sh -- fuzzy-find files with fzf preview

# Start the HTTP server in the background if not already running
curl -sf http://localhost:7654/health > /dev/null 2>&1 || {
  deepfinder --serve --port 7654 &
  sleep 1
}

# Use fzf for interactive selection
selected=$(curl -s "http://localhost:7654/search?q=&limit=10000" \
  | jq -r '.results[] | "\(.path)\t\(.name)"' \
  | fzf --delimiter='\t' --with-nth=2 --preview 'ls -lh {1}' \
  | cut -f1)

[ -n "$selected" ] && open "$selected"
```

---

## Where to Go Next

| You want to... | Read this |
|---------------|-----------|
| Learn the complete search syntax | [Search Syntax Reference](../reference/search-syntax.md) |
| See every config key and its default | [Configuration Keys Reference](../reference/config-keys.md) |
| Understand where DeepFinder stores data | [File Paths Reference](../reference/file-paths.md) |
| Manage the daemon from scripts | [Daemon Management](daemon-manage.md) |
| Integrate with other apps via URL scheme | [Integrations](../INTEGRATIONS.md) |
| Use the GUI for interactive search | [Search Panel](search-panel.md) |
