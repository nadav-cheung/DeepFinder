# DeepFinder API & SDK Reference

**Version**: 3.0.0 | **IPC Protocol**: v1 | **Last Updated**: 2026-06-03

DeepFinder provides four integration surfaces: a Unix domain socket IPC protocol (the primary API), a local HTTP API, a `deepfinder://` URL scheme, and an AppleScript/Shortcuts bridge. This document covers all of them, with copy-paste-able examples.

---

## Table of Contents

1. [IPC Protocol Specification](#1-ipc-protocol-specification)
2. [SearchQuery Reference](#2-searchquery-reference)
3. [SearchResult Reference](#3-searchresult-reference)
4. [FileRecord Schema](#4-filerecord-schema)
5. [HTTP API Reference](#5-http-api-reference)
6. [URL Scheme Reference](#6-url-scheme-reference)
7. [AppleScript & Shortcuts Integration](#7-applescript--shortcuts-integration)
8. [CLI Scripting Guide](#8-cli-scripting-guide)
9. [Versioning & Deprecation Policy](#9-versioning--deprecation-policy)
10. [Client Library Examples](#10-client-library-examples)

---

## 1. IPC Protocol Specification

### 1.1 Overview

DeepFinder uses a **request-response IPC protocol** over a Unix domain socket for all search queries and daemon management. The daemon listens on a socket file; the CLI, GUI, and third-party clients connect to it.

| Property | Value |
|----------|-------|
| **Transport** | Unix domain socket (`AF_UNIX`, `SOCK_STREAM`) |
| **Socket path** | `~/.deep-finder/session/ipc.sock` |
| **Framing** | 4-byte big-endian length prefix + JSON body |
| **Encoding** | UTF-8 JSON |
| **Max message size** | 16 MB |
| **Max query length** | 10,240 characters |
| **Protocol version** | 1 (embedded in every `IPCRequest`) |

### 1.2 Wire Format

Every message on the wire is:

```
┌──────────────────────┬──────────────────────────────┐
│  4 bytes (big-endian) │  JSON payload (UTF-8)        │
│  payload length       │                              │
└──────────────────────┴──────────────────────────────┘
```

- The **length prefix** is a `UInt32` in network byte order (big-endian).
- The **payload** is the JSON-encoded `IPCRequest` or `IPCResponse`.
- The receiver reads 4 bytes, decodes the length, then reads exactly that many bytes of JSON.

This framing allows multiple requests/responses over a single persistent connection. The wire is debuggable with `nc -U`:

```bash
# Manually send a query (length-prefixed JSON)
echo -n '{"kind":"query","query":"hello.txt","ipcProtocolVersion":1}' \
  | perl -e 'print pack("N", length(<>)), <>' \
  | nc -U ~/.deep-finder/session/ipc.sock
```

### 1.3 IPCRequest — Client to Daemon

All requests are `IPCRequest` enum variants encoded as JSON with a `kind` discriminator and `ipcProtocolVersion` field.

#### 1.3.1 `query` — Execute a Search

```json
{
  "kind": "query",
  "ipcProtocolVersion": 1,
  "query": "hello.txt",
  "limit": 100
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `kind` | string | Yes | Must be `"query"` |
| `ipcProtocolVersion` | integer | Yes | Must be `1` |
| `query` | string | Yes | Search query (max 10,240 chars) |
| `limit` | integer | No | Max results to return. Omit for no limit. |

#### 1.3.2 `cancel` — Cancel an In-Flight Query

```json
{
  "kind": "cancel",
  "ipcProtocolVersion": 1,
  "queryID": "a1b2c3d4"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `kind` | string | Yes | Must be `"cancel"` |
| `ipcProtocolVersion` | integer | Yes | Must be `1` |
| `queryID` | string | Yes | The identifier returned in the `.results` response |

#### 1.3.3 `stats` — Daemon Statistics

```json
{
  "kind": "stats",
  "ipcProtocolVersion": 1
}
```

No additional fields. Returns a `DaemonStats` object.

#### 1.3.4 `configGet` — Read Configuration

```json
{
  "kind": "configGet",
  "ipcProtocolVersion": 1,
  "key": "theme"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `kind` | string | Yes | Must be `"configGet"` |
| `ipcProtocolVersion` | integer | Yes | Must be `1` |
| `key` | string | No | Config key to read. Omit to get all keys. |

#### 1.3.5 `configSet` — Write Configuration

```json
{
  "kind": "configSet",
  "ipcProtocolVersion": 1,
  "key": "theme",
  "value": "dark"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `kind` | string | Yes | Must be `"configSet"` |
| `ipcProtocolVersion` | integer | Yes | Must be `1` |
| `key` | string | Yes | Config key to set |
| `value` | string | Yes | Config value to write |

#### 1.3.6 `indexStatus` — Index State

```json
{
  "kind": "indexStatus",
  "ipcProtocolVersion": 1
}
```

No additional fields. Returns a `DaemonIndexStatus` object.

### 1.4 IPCResponse — Daemon to Client

All responses are `IPCResponse` enum variants with a `kind` discriminator.

#### 1.4.1 `results` — Search Results

```json
{
  "kind": "results",
  "queryID": "a1b2c3d4",
  "results": [
    {
      "record": { ... },
      "providerID": "file-index",
      "score": 1.0,
      "matchType": "exact"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Always `"results"` |
| `queryID` | string | Unique identifier for this query (use with `cancel`) |
| `results` | array of `SearchResult` | Matching results, sorted by relevance |

#### 1.4.2 `error` — Error Response

```json
{
  "kind": "error",
  "error": "queryError"
}
```

`IPCError` variants:

| Error | Description |
|-------|-------------|
| `daemonNotReady` | Daemon still starting up, index not yet loaded |
| `queryError` | Query syntax error or query too long (>10,240 chars) |
| `invalidRequest` | Request missing required fields or malformed |
| `permissionDenied` | Operation requires Full Disk Access |
| `incompatibleProtocolVersion` | Client protocol version is newer than daemon supports |

#### 1.4.3 `stats` — Daemon Stats

```json
{
  "kind": "stats",
  "stats": {
    "totalFiles": 1234567,
    "indexState": "live",
    "uptimeSeconds": 3600.0,
    "memoryUsageMB": 245.5
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `totalFiles` | integer | Total files in the index |
| `indexState` | string | One of: `"stale"`, `"verifying"`, `"live"`, `"polling"` |
| `uptimeSeconds` | float | Seconds since daemon process started |
| `memoryUsageMB` | float | Approximate RSS in megabytes |

#### 1.4.4 `indexStatus` — Index State

```json
{
  "kind": "indexStatus",
  "indexStatus": {
    "state": "live",
    "filesIndexed": 1234567,
    "lastScanDate": "2026-06-03T10:30:00Z"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `state` | string | Index state: `"stale"`, `"verifying"`, `"live"`, `"polling"` |
| `filesIndexed` | integer | Number of files currently indexed |
| `lastScanDate` | string or null | ISO 8601 timestamp of last full scan |

#### 1.4.5 `ack` — Acknowledgment

```json
{
  "kind": "ack"
}
```

Sent for commands that do not return data (`configSet`, `cancel`).

### 1.5 Request/Response Lifecycle

```
Client                          Daemon
  │                                │
  ├──── connect() ────────────────►│  Unix domain socket
  │                                │
  ├──── IPCRequest (.query) ──────►│  4-byte len + JSON
  │                                │
  │                     Processing │  SearchCoordinator → InMemoryIndex
  │                                │
  │◄─── IPCResponse (.results) ────┤  4-byte len + JSON
  │                                │
  ├──── IPCRequest (.cancel) ─────►│  Cancel in-flight query
  │                                │
  │◄─── IPCResponse (.ack) ────────┤
  │                                │
  ├──── close() ──────────────────►│
```

- The daemon is **single-threaded per-request** but accepts multiple concurrent clients (up to 50).
- Responses arrive async; queryID allows clients to match responses to requests.
- Rate limit: 10 new connections/second. Exceeding this results in connection refusal.
- Connection timeout: 30 seconds of inactivity.

---

## 2. Search Query Reference

### 2.1 Query Syntax

DeepFinder accepts plain text queries with inline filter modifiers. The query string supports:

**Basic text search** (case-insensitive, NFC-normalized, Unicode-aware):

```
deepfinder "hello.txt"           # Exact match
deepfinder "report"              # Substring match (prefix prioritized)
```

**Pinyin search** (Chinese filenames):

```
deepfinder "baogao"              # Matches 报告.pdf, 报表.xlsx
deepfinder "zhongwen"            # Matches 中文相关文件.txt
```

**Glob patterns**:

```
deepfinder "*.pdf"              # All PDFs
deepfinder "photo*.jpg"         # Photos starting with "photo"
deepfinder "screen???.png"      # Screenshots with 3 digits
```

### 2.2 Filter Modifiers

Filters are specified as `key:value` pairs appended to the query. Multiple filters combine with AND semantics.

#### Size Filters

| Modifier | Example | Matches |
|----------|---------|---------|
| `size:>N` | `size:>1mb` | Files larger than 1 MB |
| `size:<N` | `size:<10mb` | Files smaller than 10 MB |
| `size:N..M` | `size:100kb..5mb` | Files between 100 KB and 5 MB |

**Unit suffixes**: `b` (bytes), `kb`/`k` (kilobytes), `mb`/`m` (megabytes), `gb`/`g` (gigabytes).

```bash
deepfinder "report size:>1mb"          # Reports larger than 1 MB
deepfinder "size:500kb..2mb"           # Files 500 KB to 2 MB (any name)
```

#### Extension Filters

| Modifier | Example | Matches |
|----------|---------|---------|
| `ext:<ext>` | `ext:pdf` | Files with .pdf extension |
| `ext:<ext>;...` | `ext:pdf;doc;txt` | Files matching any listed extension |

```bash
deepfinder "ext:swift"                  # All Swift source files
deepfinder "report ext:pdf;docx"       # Reports in PDF or DOCX format
```

#### Type (File/Directory) Filters

| Modifier | Matches |
|----------|---------|
| `file:` | Regular files only |
| `folder:` | Directories only |

```bash
deepfinder "projects folder:"          # Directories named "projects"
deepfinder "deepfinder file: ext:swift" # Swift files named "deepfinder"
```

#### Date Modified Filters

| Modifier | Example | Matches |
|----------|---------|---------|
| `dm:<relative>` | `dm:today` | Modified today |
| | `dm:yesterday` | Modified yesterday |
| | `dm:thisweek` | Modified this week |
| | `dm:last7days` | Modified in last 7 days |
| | `dm:thismonth` | Modified this month |
| | `dm:last30days` | Modified in last 30 days |
| `dm:<iso-date>` | `dm:2026-01-01` | Modified on or after Jan 1, 2026 |
| `dm:<date>..<date>` | `dm:2026-01-01..2026-06-01` | Modified in date range |

```bash
deepfinder "dm:today"                   # Files modified today
deepfinder "report dm:thisweek"         # Reports modified this week
deepfinder "dm:2026-01-01..2026-03-31"  # Q1 2026 files
```

#### Depth Filters

| Modifier | Example | Matches |
|----------|---------|---------|
| `depth:N` | `depth:3` | Path depth <= 3 components |
| `depth:<=N` | `depth:<=2` | Path depth <= 2 |
| `depth:>=N` | `depth:>=4` | Path depth >= 4 |
| `depth:>N` | `depth:>3` | Path depth > 3 |
| `depth:<N` | `depth:<5` | Path depth < 5 |

Depth is the number of path components. `/Users/nadav/Documents/report.pdf` has depth 4.

```bash
deepfinder "depth:1"                    # Top-level files only
deepfinder "depth:>=5"                  # Deeply nested files
```

#### Media Metadata Filters

| Modifier | Example | Matches |
|----------|---------|---------|
| `width:>N` | `width:>1920` | Images wider than 1920px |
| `height:>N` | `height:>1080` | Images taller than 1080px |
| `duration:N..M` | `duration:60..300` | Audio/video 1-5 minutes |
| `pages:>N` | `pages:>50` | PDFs with more than 50 pages |
| `pageCount:>N` | `pageCount:>50` | Same as pages (alias) |
| `fps:>N` | `fps:>=60` | Video >= 60 FPS |
| `bitRate:>N` | `bitRate:>320` | Audio bitrate > 320 kbps |
| `artist:<text>` | `artist:beatles` | Tracks by artist |
| `album:<text>` | `album:abbey` | Tracks on album matching |
| `title:<text>` | `title:spring` | Tracks with title containing |
| `genre:<text>` | `genre:rock` | Tracks with genre |
| `codec:<text>` | `codec:aac` | Files with codec |

Numeric operators supported: `>`, `<`, `>=`, `<=`, `N..M` (range), `N` (exact).

```bash
deepfinder "ext:jpg width:>3840"        # Ultra-wide images
deepfinder "duration:>600 ext:mp4"      # Videos longer than 10 minutes
deepfinder "artist:chopin ext:flac"     # Chopin in lossless format
```

### 2.3 Search Query Internal Representation

When the daemon receives a query string, it creates a `SearchQuery`:

```swift
struct SearchQuery {
    let rawQuery: String           // Original user input, preserved verbatim
    let normalizedQuery: String    // NFC-normalized + lowercased for matching
}
```

The normalized form applies `precomposedStringWithCanonicalMapping` (NFC) then `lowercased()`. All matching is done against this normalized form against the `name` field of every `FileRecord` (which is also NFC-normalized and lowercased at indexing time).

---

## 3. SearchResult Reference

A `SearchResult` is a Codable struct returned in the `IPCResponse.results` array.

```json
{
  "record": { ... },
  "providerID": "file-index",
  "score": 1.0,
  "matchType": "exact"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `record` | `FileRecord` | The matched file's full metadata (see Section 4) |
| `providerID` | string | Identifier of the search provider (e.g., `"file-index"`, `"content"`, `"ai-semantic"`) |
| `score` | float | Relevance score (higher = more relevant). Provider-defined; 1.0 = maximum confidence. |
| `matchType` | string | How the query matched. See MatchType table below. |

### 3.1 MatchType Values

| matchType | Priority | Description |
|-----------|----------|-------------|
| `"exact"` | Highest | Query exactly matches the full filename (case-insensitive) |
| `"prefix"` | High | Query matches the beginning of the filename |
| `"pinyin"` | Medium | Query matched via pinyin transliteration of Chinese characters |
| `"substring"` | Normal | Query appears as a substring anywhere in the filename |

MatchType is encoded as an integer in the JSON: `0`=exact, `1`=prefix, `2`=pinyin, `3`=substring.

### 3.2 Result Ordering

Results are sorted by:
1. **MatchType priority** (exact > prefix > pinyin > substring)
2. **Relevance score** (within same MatchType, higher scores first)
3. **Natural sort on filename** (as tiebreaker)

When using `--sort name|size|date`, this default ordering is replaced by the specified criterion.

---

## 4. FileRecord Schema

Every `SearchResult.record` is a `FileRecord` — an immutable, Codable struct representing a single file or directory in the index.

```json
{
  "id": 42,
  "name": "report.pdf",
  "originalName": "Report.pdf",
  "path": "/Users/nadav/Documents/Report.pdf",
  "parentPath": "/Users/nadav/Documents",
  "isDirectory": false,
  "size": 245760,
  "createdAt": "2026-01-15T10:30:00Z",
  "modifiedAt": "2026-06-03T14:22:00Z",
  "extension": "pdf",
  "metadata": {
    "fileExtension": "pdf",
    "fields": {
      "pageCount": { "integer": 42 },
      "title": { "string": "Q4 Report" }
    }
  }
}
```

### 4.1 Core Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | `UInt32` | Unique numeric identifier within this index instance |
| `name` | string | NFC-normalized + lowercased filename used for search matching |
| `originalName` | string | Original filename as it appears on disk, preserved for display |
| `path` | string | Absolute path (e.g., `"/Users/nadav/Documents/report.pdf"`) |
| `parentPath` | string | Absolute path to the parent directory |
| `isDirectory` | bool | `true` for directories, `false` for regular files |
| `size` | `Int64` | File size in bytes. Zero for directories. |
| `createdAt` | ISO 8601 string | File creation date from filesystem metadata |
| `modifiedAt` | ISO 8601 string | Last modification date from filesystem metadata |
| `extension` | string or null | File extension without leading dot (e.g., `"pdf"`, `"swift"`). `null` for directories. |
| `metadata` | `ExtractedMetadata` or null | Optional media metadata (see 4.2) |

### 4.2 ExtractedMetadata (Media Files)

Only present for media files with extractable metadata (images, audio, video, PDFs). `null` for regular files.

```json
{
  "fileExtension": "jpg",
  "fields": {
    "width": { "integer": 4032 },
    "height": { "integer": 3024 },
    "dpi": { "double": 72.0 },
    "camera": { "string": "iPhone 15 Pro" }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `fileExtension` | string | File extension used to select the metadata extractor (lowercase, no dot) |
| `fields` | dict of `MetadataValue` | Named metadata fields with typed values |

### 4.3 MetadataValue

A polymorphic union of four types, encoded as tagged JSON:

| JSON Representation | Swift Case | Example |
|---------------------|------------|---------|
| `{"string":"value"}` | `.string(String)` | Artist name, codec, title |
| `{"integer":42}` | `.integer(Int)` | Width, page count, bitrate |
| `{"double":72.5}` | `.double(Double)` | Duration (seconds), DPI |
| `{"date":"2026-01-01T00:00:00Z"}` | `.date(Date)` | EXIF creation date, PDF mod date |

### 4.4 Standard Metadata Keys

| Key | Type | File Types | Description |
|-----|------|-----------|-------------|
| `width` | integer | Images, Video | Width in pixels |
| `height` | integer | Images, Video | Height in pixels |
| `duration` | double | Audio, Video | Duration in seconds |
| `dpi` | double | Images | Dots per inch |
| `camera` | string | Images | Camera model from EXIF |
| `artist` | string | Audio | Artist/performer |
| `album` | string | Audio | Album name |
| `title` | string | Audio, Video | Track/video title |
| `genre` | string | Audio | Music genre |
| `codec` | string | Audio, Video | Codec identifier |
| `bitRate` | integer | Audio, Video | Bitrate in kbps |
| `fps` | double | Video | Frames per second |
| `pageCount` | integer | PDF | Number of pages |

### 4.5 Unicode Normalization

- **`name`**: On ingestion, the raw filename is NFC-normalized via `precomposedStringWithCanonicalMapping`, then lowercased. This is the field matched against queries.
- **`originalName`**: The raw filename as read from the filesystem, unmodified. Use this for display.
- Query strings are also NFC-normalized and lowercased before matching, ensuring consistent behavior regardless of Unicode normalization form in the input.

---

## 5. HTTP API Reference

### 5.1 Overview

DeepFinder can expose a lightweight HTTP API at `http://127.0.0.1:7654` using `--serve` mode. It uses Network.framework with zero external dependencies.

| Property | Value |
|----------|-------|
| **Bind address** | 127.0.0.1 (localhost only — not exposed to network) |
| **Default port** | 7654 (configurable with `--port`) |
| **Transport** | HTTP/1.1 over TCP |
| **Content type** | `application/json` |
| **CORS** | `Access-Control-Allow-Origin: *` (for browser-based tooling) |
| **Auth** | Bearer token (auto-generated UUID per start) |
| **Connection** | `close` (no keep-alive) |

### 5.2 Starting the HTTP Server

```bash
# Start HTTP server on default port 7654
deepfinder --serve

# Start on a custom port
deepfinder --serve --port 8080
```

The server runs in the foreground. It prints the auth token on startup:

```
HTTP search service listening on http://127.0.0.1:7654
Auth token: a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

The token is also written to `~/.deep-finder/session/http-token` (permissions 600) so trusted local clients can read it from disk.

### 5.3 Authentication

All endpoints except `/health` require authentication. Supply the token in one of two ways:

**Query parameter**:
```
GET /search?q=hello&token=a1b2c3d4-...
```

**Authorization header**:
```
Authorization: Bearer a1b2c3d4-...
```

### 5.4 Endpoints

#### `GET /health` — Health Check (Unauthenticated)

```bash
curl http://127.0.0.1:7654/health
```

**Response** `200 OK`:
```json
{"status":"ok"}
```

#### `GET /search` — Search Files

Performs a file search and returns matching results.

**Parameters**:

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `q` | string | Yes | — | Search query string |
| `limit` | integer | No | 100 | Maximum results to return |
| `offset` | integer | No | 0 | Number of results to skip (pagination) |
| `token` | string | Yes* | — | Auth token (*or use Authorization header) |

```bash
curl "http://127.0.0.1:7654/search?q=report.pdf&limit=5&token=YOUR_TOKEN"
```

**Response** `200 OK`:
```json
{
  "query": "report.pdf",
  "results": [
    {
      "id": "42",
      "name": "report.pdf",
      "originalName": "Q4 Report.pdf",
      "path": "/Users/nadav/Documents/Q4 Report.pdf",
      "parentPath": "/Users/nadav/Documents",
      "isDirectory": "false",
      "size": "245760",
      "createdAt": "2026-01-15T10:30:00Z",
      "modifiedAt": "2026-06-03T14:22:00Z",
      "extension": "pdf",
      "providerID": "file-index",
      "score": "1.0",
      "matchType": "exact"
    }
  ],
  "total": 1,
  "offset": 0,
  "limit": 5
}
```

**Notes**:
- The HTTP API returns results as flat dictionaries (not the full `SearchResult` wrapping). Each result merges `FileRecord` fields with `providerID`, `score`, and `matchType`.
- Numeric fields (`id`, `size`, `score`) are serialized as strings in the HTTP response — parse them as needed.

#### `GET /stats` — Index Statistics

```bash
curl "http://127.0.0.1:7654/stats?token=YOUR_TOKEN"
```

**Response** `200 OK`:
```json
{
  "totalFiles": 1234567,
  "indexState": "live",
  "uptimeSeconds": 3600.0,
  "memoryUsageMB": 245.5
}
```

### 5.5 Error Responses

| Status | Body | When |
|--------|------|------|
| `400 Bad Request` | `{"error":"Bad request"}` | Malformed HTTP request |
| `401 Unauthorized` | `{"error":"Unauthorized"}` | Missing or invalid auth token |
| `404 Not Found` | `{"error":"Not found"}` | Unknown endpoint path |
| `405 Method Not Allowed` | `{"error":"Method not allowed"}` | Non-GET request |

### 5.6 Rate Limits

The HTTP server applies the same rate limits as the IPC layer:
- 10 new connections per second (enforced at the daemon level)
- 50 concurrent clients maximum
- Exceeding limits results in connection refusal (TCP-level, before HTTP parsing)

### 5.7 Full Workflow Example

```bash
# Terminal 1: Start the HTTP server
deepfinder --serve
# → HTTP search service listening on http://127.0.0.1:7654
# → Auth token: c8d9e0f1-a2b3-4c5d-6e7f-890123456789

# Terminal 2: Use the API
TOKEN=$(cat ~/.deep-finder/session/http-token)

# Health check
curl http://127.0.0.1:7654/health

# Search
curl -s "http://127.0.0.1:7654/search?q=*.swift&limit=3&token=$TOKEN" | python3 -m json.tool

# Stats
curl -s "http://127.0.0.1:7654/stats?token=$TOKEN" | python3 -m json.tool
```

---

## 6. URL Scheme Reference

### 6.1 Overview

DeepFinder registers the `deepfinder://` URL scheme. Any application can open these URLs to trigger a search in the DeepFinder GUI.

### 6.2 Supported Actions

#### `deepfinder://search` — Open Search with Query

```
deepfinder://search?q=<query>&limit=<n>&filter=<expr>
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `q` | string | Yes | Search query (URL-encoded) |
| `limit` | integer | No | Maximum results (positive integer) |
| `filter` | string | No | Filter expression (e.g., `"ext:pdf"`) |

**Examples**:

```
deepfinder://search?q=report.pdf
deepfinder://search?q=photo&limit=50&filter=ext%3Ajpg
deepfinder://search?q=hello%20world
```

### 6.3 Opening from Applications

**From Terminal**:
```bash
open "deepfinder://search?q=report.pdf"
open "deepfinder://search?q=photo&limit=50&filter=ext%3Ajpg"
```

**From a web browser**:
```html
<a href="deepfinder://search?q=report.pdf">Find report.pdf</a>
```

**From JavaScript**:
```javascript
window.location.href = "deepfinder://search?q=" + encodeURIComponent("report.pdf");
```

### 6.4 URL Parsing

URLs are parsed by the `SearchURL.parse(_:)` function with strict validation:
- Scheme must be `"deepfinder"`
- Host must be `"search"`
- The `q` parameter must be present and non-empty
- Invalid URLs silently fail (return `nil`), producing no action

---

## 7. AppleScript & Shortcuts Integration

### 7.1 AppleScript

DeepFinder exposes a `search` command for AppleScript automation.

**sdef vocabulary**:

```
search text : Search for files by name using DeepFinder
    search string  -- the search query
    [limit integer] : maximum number of results (default: 20)
    Result: list of text  -- matching file paths
```

**Example scripts**:

```applescript
-- Basic search
tell application "DeepFinder"
    search "report.pdf"
end tell
-- Returns: {"/Users/nadav/Documents/Q4 Report.pdf", "/Users/nadav/Desktop/report.pdf"}

-- Search with limit
tell application "DeepFinder"
    search "*.swift" with limit 50
end tell

-- Use results in a loop
tell application "DeepFinder"
    set pdfFiles to search "ext:pdf dm:today"
    repeat with f in pdfFiles
        -- Process each file
        display dialog "Found: " & f
    end repeat
end tell

-- Open the first result
tell application "DeepFinder"
    set results to search "config.json"
    if (count of results) > 0 then
        do shell script "open " & quoted form of (item 1 of results)
    end if
end tell
```

### 7.2 Apple Shortcuts (Siri / App Intents)

DeepFinder provides a `SearchFilesIntent` for Shortcuts automation.

**Shortcut action**: "Search Files"

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| Query | Text | Yes | — | Search query string |
| Limit | Number | No | 20 | Maximum results to return |

**Output**: List of file paths (text). The output can be passed to subsequent Shortcut actions (Open File, Get File Info, Copy to Clipboard, etc.).

**Example Shortcut workflow**:

```
1. Search Files (query: "ext:png dm:today", limit: 10)
2. For Each (item in Search Results)
3.   Quick Look (item)
4. End For Each
```

This searches for today's PNG files and previews them one by one.

### 7.3 Technical Details

- AppleScript commands use a 5-second timeout when communicating with the daemon via IPC.
- If the daemon is not running, the command returns an empty list (no error raised to the AppleScript caller).
- The `DeepFinderSearchCommand` class (subclass of `NSScriptCommand`) handles the bridge: it wraps `IPCClient.send(_:)` in a `DispatchSemaphore` to provide synchronous behavior from the asynchronous IPC layer.
- Shortcuts use `AppIntents` framework (`SearchFilesIntent`) and similarly return an empty array on daemon unavailability.

---

## 8. CLI Scripting Guide

### 8.1 Output Formats

DeepFinder supports three output modes for programmatic use.

#### Default (Human-Readable)

```bash
deepfinder "hello.txt"
```
```
[1] /Users/nadav/Documents/hello.txt (12 KB)
[2] /Users/nadav/Desktop/hello.txt (8 KB)
```

#### `--json` — Machine-Readable JSON Output

```bash
deepfinder --json "hello.txt"
```

```json
[
  {
    "id": 42,
    "name": "hello.txt",
    "originalName": "hello.txt",
    "path": "/Users/nadav/Documents/hello.txt",
    "parentPath": "/Users/nadav/Documents",
    "isDirectory": false,
    "size": 12288,
    "createdAt": "2026-01-15T10:30:00Z",
    "modifiedAt": "2026-06-03T14:22:00Z",
    "extension": "txt"
  }
]
```

Use with `jq`:

```bash
# Extract all file paths
deepfinder --json "*.pdf" | jq -r '.[].path'

# Count results
deepfinder --json "*.swift" | jq 'length'

# Filter by modification date
deepfinder --json "report" | jq '.[] | select(.modifiedAt > "2026-01-01") | .path'
```

#### `--0` — Null-Delimited Output (for `xargs`)

```bash
deepfinder --0 "*.log"
```
Outputs one file path per line, terminated by a null byte (`\0`). Safe for filenames containing spaces and newlines.

```bash
# Delete all .tmp files
deepfinder --0 "*.tmp" | xargs -0 rm

# Process each result safely
deepfinder --0 "*.jpg" | while IFS= read -r -d '' path; do
    echo "Processing: $path"
    sips -Z 800 "$path"
done

# Count results
deepfinder --0 "*.swift" | tr '\0' '\n' | wc -l
```

### 8.2 Exit Codes

| Code | Meaning | When |
|------|---------|------|
| `0` | Success | Query returned one or more results |
| `1` | No results | Query executed but found nothing matching |
| `2` | Daemon error | Daemon not running or unresponsive |
| `3` | Query error | Invalid query syntax or query too long |

```bash
# Conditional logic based on results
if deepfinder --json "config.yaml" | jq -e 'length > 0' > /dev/null; then
    echo "Found config files"
else
    echo "No config files found"
fi

# Check daemon status
deepfinder daemon status
echo "Exit code: $?"
# 0 = running, 1 = not running
```

### 8.3 Sorting & Pagination

```bash
# Sort by name (default)
deepfinder --sort name "*.swift"

# Sort by modification date, newest first
deepfinder --sort date --reverse "*.swift"

# Sort by size, largest first
deepfinder --sort size --reverse "report"

# Paginate: results 101-150
deepfinder --limit 50 --offset 100 "*.log"

# Verbose mode: show match type and score per result
deepfinder --verbose "hello.txt"
```

### 8.4 Subcommands for Automation

```bash
# Daemon lifecycle
deepfinder daemon start        # Start daemon (returns immediately)
deepfinder daemon stop         # Stop daemon gracefully
deepfinder daemon restart      # Restart daemon
deepfinder daemon status       # Show PID, uptime, file count (JSON with --json)

# Configuration
deepfinder config get theme              # Read a config value
deepfinder config set theme dark         # Set a config value
deepfinder config list                   # List all config
deepfinder config reset                  # Reset to defaults

# Installation
deepfinder install                       # Install LaunchAgent (auto-start on login)
deepfinder uninstall                     # Remove LaunchAgent
```

### 8.5 Piping Patterns

```bash
# Find + open in Finder
deepfinder --0 "report.pdf" | xargs -0 -I {} open -R "{}"

# Find + get file info
deepfinder --0 "*.mov" | xargs -0 mdls

# Find largest files
deepfinder --json --sort size --reverse --limit 10 | jq '.[] | "\(.path) (\(.size) bytes)"'

# Find recently modified
deepfinder --json --sort date --reverse --limit 10 | jq '.[] | "\(.modifiedAt) \(.path)"'

# Watch for new files (poll-based)
watch -n 5 'deepfinder --sort date --reverse --limit 5'

# Find duplicates with the same name
deepfinder --json "report.pdf" | jq -r 'group_by(.name) | .[] | select(length > 1) | .[].path'
```

### 8.6 Daemon Subcommands with JSON

```bash
# Daemon status as JSON
deepfinder --json daemon status
```
```json
{
  "pid": 12345,
  "running": true,
  "uptime": "2h 15m",
  "filesIndexed": 1234567,
  "indexState": "live"
}
```

```bash
# Config list as JSON
deepfinder --json config list
```
```json
{
  "theme": "dark",
  "maxResults": 1000,
  "followSymlinks": false
}
```

---

## 9. Versioning & Deprecation Policy

### 9.1 IPC Protocol Versioning

The IPC protocol version (`ipcProtocolVersion`) is embedded in every `IPCRequest` and checked by the daemon before processing.

| Version | DeepFinder Version | Changes |
|---------|-------------------|---------|
| `1` | 1.0.0+ | Initial protocol version |

**Compatibility rules**:
- **Forward compatibility**: A newer client sending a higher `ipcProtocolVersion` than the daemon supports receives an `incompatibleProtocolVersion` error. The client should either downgrade or prompt the user to upgrade the daemon.
- **Backward compatibility**: The daemon accepts requests from clients with version <= daemon's supported version. Old clients get old behavior; new features added in newer protocol versions are simply not available.
- **Version negotiation**: Clients should send the highest version they understand. The daemon decides which features to enable based on the negotiated version.

### 9.2 HTTP API Versioning

The HTTP API does not use explicit versioning. Breaking changes will be avoided within the same major DeepFinder version (3.x). If a breaking change becomes necessary:

1. The old endpoint behavior is preserved for one minor version.
2. A deprecation warning is added to the response headers: `X-Deprecated: true`.
3. Documentation marks the endpoint as deprecated with migration instructions.
4. The old behavior is removed in the next major version.

### 9.3 Semantic Versioning for DeepFinder

| Bump | Trigger |
|------|---------|
| **Major** (3.0 → 4.0) | Breaking IPC protocol change, incompatible daemon/CLI API |
| **Minor** (3.0 → 3.1) | New IPC message types, new HTTP endpoints, new filter modifiers |
| **Patch** (3.0.0 → 3.0.1) | Bug fixes, performance improvements, no API changes |

### 9.4 Deprecation Process

1. **Announce**: Deprecated features are noted in the changelog and documented with `**Deprecated**` tags.
2. **Grace period**: Features remain functional for at least one minor version after deprecation announcement.
3. **Warning**: Using a deprecated feature logs a warning to the daemon log (`~/.deep-finder/logs/daemon.log`).
4. **Removal**: Deprecated features are removed in the next major version.

---

## 10. Client Library Examples

### 10.1 Swift (Native)

The `IPCClient` actor in `Sources/Daemon/IPCClient.swift` is the canonical Swift client. You can use it directly in any Swift project that links against the `DeepFinder` module.

```swift
import DeepFinder

// Create client
let client = IPCClient(socketPath: Product.socketPath)

// Ensure daemon is running (auto-spawn if needed)
try await client.ensureDaemonRunning()

// Send a query
let request: IPCRequest = .query("report.pdf", limit: 10)
let response = try await client.send(request)

switch response {
case .results(let results, let queryID):
    for result in results {
        print("\(result.record.path) [\(result.matchType)]")
    }
case .error(let error):
    print("Error: \(error)")
default:
    break
}

// Get daemon stats
let statsRequest: IPCRequest = .stats
let statsResponse = try await client.send(statsRequest)
if case .stats(let stats) = statsResponse {
    print("Indexed \(stats.totalFiles) files, state: \(stats.indexState)")
}
```

### 10.2 Python

A minimal Python client using raw sockets and JSON.

```python
#!/usr/bin/env python3
"""DeepFinder IPC client example."""
import json
import os
import socket
import struct
import sys

SOCKET_PATH = os.path.expanduser("~/.deep-finder/session/ipc.sock")


def send_request(request: dict) -> dict:
    """Send an IPCRequest and return the IPCResponse."""
    payload = json.dumps(request).encode("utf-8")

    # 4-byte big-endian length prefix
    header = struct.pack(">I", len(payload))

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    sock.sendall(header + payload)

    # Read 4-byte length prefix
    len_bytes = sock.recv(4)
    if len(len_bytes) < 4:
        raise ValueError("Server closed connection before sending response length")

    response_len = struct.unpack(">I", len_bytes)[0]
    if response_len > 16 * 1024 * 1024:
        raise ValueError(f"Response too large: {response_len} bytes")

    # Read full payload
    response_data = b""
    while len(response_data) < response_len:
        chunk = sock.recv(min(8192, response_len - len(response_data)))
        if not chunk:
            break
        response_data += chunk

    sock.close()
    return json.loads(response_data)


def search(query: str, limit: int = 20):
    """Search for files matching the query."""
    request = {
        "kind": "query",
        "ipcProtocolVersion": 1,
        "query": query,
        "limit": limit,
    }
    response = send_request(request)

    if response["kind"] == "error":
        raise RuntimeError(f"Search error: {response['error']}")

    return response["results"]


def stats():
    """Get daemon statistics."""
    request = {
        "kind": "stats",
        "ipcProtocolVersion": 1,
    }
    response = send_request(request)
    return response["stats"]


# Example usage
if __name__ == "__main__":
    try:
        results = search("*.swift", limit=5)
        for r in results:
            rec = r["record"]
            print(f"{r['matchType']:10} {rec['path']} ({rec['size']} bytes)")
    except FileNotFoundError:
        print("Daemon not running. Start it with: deepfinder daemon start", file=sys.stderr)
        sys.exit(2)
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(3)
```

### 10.3 Shell (Bash/Zsh)

A lightweight shell client using `nc` (netcat) for one-off queries.

```bash
#!/usr/bin/env bash
# deepfinder-search — shell-based IPC client
# Usage: ./deepfinder-search "query" [limit]

SOCKET="${HOME}/.deep-finder/session/ipc.sock"
QUERY="${1:?Usage: $0 <query> [limit]}"
LIMIT="${2:-100}"

# Build JSON request
REQUEST=$(cat <<EOF
{"kind":"query","ipcProtocolVersion":1,"query":"$QUERY","limit":$LIMIT}
EOF
)

# Encode: 4-byte big-endian length prefix + JSON
# Using perl for reliable binary header construction
send_request() {
    local json="$1"
    # perl: pack N = 32-bit big-endian unsigned integer
    printf '%s' "$json" | perl -e '
        local $/;
        my $json = <STDIN>;
        print pack("N", length($json));
        print $json;
    '
}

# Send request and decode response
RESPONSE=$(send_request "$REQUEST" | nc -U "$SOCKET" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo '{"error":"daemon not running"}' >&2
    exit 2
fi

# Strip 4-byte length prefix and parse JSON
echo "$RESPONSE" | tail -c +5 | python3 -m json.tool 2>/dev/null || {
    echo "Failed to parse response" >&2
    exit 3
}
```

### 10.4 Python HTTP Client

Using the HTTP API (requires `--serve` running).

```python
#!/usr/bin/env python3
"""DeepFinder HTTP API client."""
import json
import os
import sys
import urllib.request
import urllib.parse


def get_token() -> str:
    """Read the auth token from disk."""
    token_path = os.path.expanduser("~/.deep-finder/session/http-token")
    with open(token_path) as f:
        return f.read().strip()


def search(query: str, base_url: str = "http://127.0.0.1:7654",
           limit: int = 20, offset: int = 0):
    """Search using the HTTP API."""
    token = get_token()
    params = {
        "q": query,
        "limit": str(limit),
        "offset": str(offset),
        "token": token,
    }
    url = f"{base_url}/search?{urllib.parse.urlencode(params)}"

    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


def stats(base_url: str = "http://127.0.0.1:7654"):
    """Get daemon stats via HTTP."""
    token = get_token()
    url = f"{base_url}/stats?token={token}"
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


def health(base_url: str = "http://127.0.0.1:7654"):
    """Check health (no auth required)."""
    url = f"{base_url}/health"
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


if __name__ == "__main__":
    try:
        h = health()
        print(f"Daemon: {h}")

        results = search("report.pdf", limit=5)
        print(f"Found {results['total']} results for '{results['query']}':")
        for r in results["results"]:
            print(f"  {r['path']} ({r['size']} bytes)")

        s = stats()
        print(f"\nIndex: {s['filesIndexed']} files, state: {s['indexState']}")
    except FileNotFoundError:
        print("Auth token not found. Is --serve running?", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Connection error: {e}", file=sys.stderr)
        sys.exit(2)
```

---

## Appendix A: File Paths Reference

All runtime files live under `~/.deep-finder/`:

| Path | Purpose | Permissions |
|------|---------|-------------|
| `~/.deep-finder/session/ipc.sock` | Unix domain socket for daemon IPC | `0700` dir |
| `~/.deep-finder/session/daemon.pid` | Daemon PID file | `0644` |
| `~/.deep-finder/session/http-token` | HTTP API auth token | `0600` |
| `~/.deep-finder/cache/index.db` | SQLite WAL index database | `0600` |
| `~/.deep-finder/settings.json` | User configuration | `0600` |
| `~/.deep-finder/.env` | Secrets / API keys | `0600` |
| `~/.deep-finder/history` | REPL command history | `0600` |
| `~/.deep-finder/logs/daemon.log` | Daemon log output | `0600` |

## Appendix B: Schema Definitions (JSON TypeScript-like)

For reference, the TypeScript-like type definitions for the JSON wire format:

```typescript
// === IPC Messages ===

type IPCRequest =
  | { kind: "query"; ipcProtocolVersion: 1; query: string; limit?: number }
  | { kind: "cancel"; ipcProtocolVersion: 1; queryID: string }
  | { kind: "stats"; ipcProtocolVersion: 1 }
  | { kind: "configGet"; ipcProtocolVersion: 1; key?: string }
  | { kind: "configSet"; ipcProtocolVersion: 1; key: string; value: string }
  | { kind: "indexStatus"; ipcProtocolVersion: 1 };

type IPCResponse =
  | { kind: "results"; queryID: string; results: SearchResult[] }
  | { kind: "error"; error: IPCError }
  | { kind: "stats"; stats: DaemonStats }
  | { kind: "ack" }
  | { kind: "indexStatus"; indexStatus: DaemonIndexStatus };

type IPCError =
  | "daemonNotReady"
  | "queryError"
  | "invalidRequest"
  | "permissionDenied"
  | "incompatibleProtocolVersion";

// === Results ===

interface SearchResult {
  record: FileRecord;
  providerID: string;
  score: number;          // 0.0 to 1.0
  matchType: MatchType;
}

type MatchType = "exact" | "prefix" | "pinyin" | "substring";

// === File Record ===

interface FileRecord {
  id: number;              // UInt32
  name: string;            // NFC-normalized, lowercased
  originalName: string;    // As on disk
  path: string;            // Absolute
  parentPath: string;      // Absolute
  isDirectory: boolean;
  size: number;            // Int64, bytes
  createdAt: string;       // ISO 8601
  modifiedAt: string;      // ISO 8601
  extension: string | null;
  metadata: ExtractedMetadata | null;
}

interface ExtractedMetadata {
  fileExtension: string;
  fields: Record<string, MetadataValue>;
}

type MetadataValue =
  | { string: string }
  | { integer: number }
  | { double: number }
  | { date: string };

// === Stats ===

interface DaemonStats {
  totalFiles: number;
  indexState: string;      // "stale" | "verifying" | "live" | "polling"
  uptimeSeconds: number;
  memoryUsageMB: number;
}

interface DaemonIndexStatus {
  state: string;
  filesIndexed: number;
  lastScanDate: string | null;
}
```

## Appendix C: Wire Framing Pseudocode

```
╔══════════════════════════╗
║  FRAME                   ║
║  ┌──────┬─────────────┐  ║
║  │ 4 B  │  N bytes    │  ║
║  │ len  │  JSON UTF-8 │  ║
║  │ (BE) │  payload    │  ║
║  └──────┴─────────────┘  ║
╚══════════════════════════╝

ENCODE:
  payload = JSONEncoder.encode(message)       // Data (UTF-8)
  len     = UInt32(payload.count).bigEndian   // 4 bytes, network order
  frame   = len + payload                     // contiguous Data

DECODE:
  len     = UInt32(bigEndian: frame[0..<4])
  payload = frame[4..<4+len]
  message = JSONDecoder.decode(type, from: payload)

MAX FRAME SIZE: 16 MB (enforced by IPCFramingIO)
```

---

**Maintained by**: `architect` | **Source**: Sources/Daemon/IPCProtocol.swift, Sources/Services/HTTPSearchService.swift, Sources/Services/URLSchemeHandler.swift, Sources/Services/SearchScriptCommand.swift, Sources/Services/SearchIntent.swift, Sources/CLI/ArgParser.swift
