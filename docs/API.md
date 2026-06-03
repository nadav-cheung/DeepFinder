# DeepFinder HTTP Search API

**Version**: 3.0.0

DeepFinder exposes a lightweight JSON HTTP API for local integrations. The server binds to `127.0.0.1` only -- it is never exposed to the network. No authentication or API keys are required.

Built on Network.framework `NWListener` with zero external dependencies.

## Starting the Server

```bash
# Default port (7654)
deepfinder --serve

# Custom port
deepfinder --serve --port 8080
```

Stopping: send SIGINT (Ctrl+C).

## Base URL

```
http://localhost:7654
```

## Endpoints

### GET /health

Health check. Returns whether the service is running.

**Response** `200 OK`

```json
{"status":"ok"}
```

### GET /search

Search for files by name. Case-insensitive, NFC-normalized matching.

**Query Parameters**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `q` | string | yes | - | Search query string |
| `limit` | integer | no | 100 | Maximum number of results to return |
| `offset` | integer | no | 0 | Number of results to skip (pagination) |

**Response** `200 OK`

```json
{
  "query": "report",
  "results": [
    {"path": "/Users/nadav/Documents/report.pdf", "name": "report.pdf"},
    {"path": "/Users/nadav/Documents/Q4-report.docx", "name": "Q4-report.docx"}
  ],
  "total": 2,
  "offset": 0,
  "limit": 100
}
```

Each result object contains:

| Field | Type | Description |
|---|---|---|
| `path` | string | Absolute filesystem path |
| `name` | string | Original filename as it appears on disk |

Empty results:

```json
{
  "query": "nonexistent",
  "results": [],
  "total": 0,
  "offset": 0,
  "limit": 100
}
```

### GET /stats

Index and daemon statistics.

**Response** `200 OK`

```json
{
  "totalFiles": 142853,
  "indexState": "live",
  "uptimeSeconds": 3840,
  "memoryUsageMB": 218
}
```

| Field | Type | Description |
|---|---|---|
| `totalFiles` | integer | Number of files currently indexed |
| `indexState` | string | Index state: `stale`, `verifying`, or `live` |
| `uptimeSeconds` | integer | Seconds since daemon started |
| `memoryUsageMB` | integer | Approximate memory used by the in-memory index |

## Error Responses

All errors return a JSON body with an `error` key.

| Status | Body | Condition |
|---|---|---|
| 400 | `{"error":"Bad request"}` | Unparseable HTTP request |
| 404 | `{"error":"Not found"}` | Unknown endpoint |
| 405 | `{"error":"Method not allowed"}` | Non-GET method on any endpoint |

## Headers

All responses include:

```
Content-Type: application/json
Access-Control-Allow-Origin: *
Connection: close
```

CORS headers enable browser-based integrations (dashboard widgets, Raycast extensions, Alfred workflows).

## Rate Limiting

No rate limiting is applied. The server is localhost-only and designed for low-latency in-memory queries. Concurrent requests are handled on independent dispatch queues.

## Example: curl

```bash
# Health check
curl -s http://localhost:7654/health

# Search for "report"
curl -s "http://localhost:7654/search?q=report"

# Search with pagination
curl -s "http://localhost:7654/search?q=report&limit=10&offset=0"

# Get stats
curl -s http://localhost:7654/stats

# Pretty-print with jq
curl -s "http://localhost:7654/search?q=*.swift&limit=5" | jq '.results[] | .path'
```

## Example: Browser

Open `http://localhost:7654/search?q=readme` in any browser. Results are returned as raw JSON with CORS headers, suitable for use from JavaScript fetch calls.

## Example: Alfred / Raycast

```bash
# Alfred Script Filter (JSON output consumed by Alfred)
curl -s "http://localhost:7654/search?q={query}&limit=20" | \
  jq '[.results[] | {title: .name, subtitle: .path, arg: .path}]' | \
  jq '{items: .}'
```
