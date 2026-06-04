# File Paths Reference

Every file and directory DeepFinder creates on disk, what it contains, and its permissions.

## Data Directory (`~/.deep-finder/`)

All runtime data lives under `~/.deep-finder/`. This directory is created automatically on first use. Sensitive files use permissions `600` (owner read/write only); directories use `700`.

| Path | Purpose | Permissions |
|------|---------|-------------|
| `~/.deep-finder/` | Root data directory | `700` |
| `~/.deep-finder/settings.json` | Daemon and CLI configuration (JSON) | `600` |
| `~/.deep-finder/.env` | Secrets file -- API keys, encryption key (JSON) | `600` |
| `~/.deep-finder/history` | REPL command history (plain text, max 1000 entries) | `600` |

### `session/` -- Runtime Files

Transient files created at daemon startup, removed on clean shutdown. Stale files are cleaned up on the next `daemon start`.

| Path | Purpose | Permissions |
|------|---------|-------------|
| `~/.deep-finder/session/` | Runtime session directory | `700` |
| `~/.deep-finder/session/daemon.pid` | Running daemon PID (plain text integer) | `644` |
| `~/.deep-finder/session/ipc.sock` | Unix domain socket for CLI/GUI-to-daemon IPC | socket |
| `~/.deep-finder/session/http-token` | HTTP API bearer token (when `--serve` is active) | `600` |

### `cache/` -- Rebuildable Data

Persistent data that can be reconstructed from a full filesystem scan if lost.

| Path | Purpose | Permissions |
|------|---------|-------------|
| `~/.deep-finder/cache/` | Cache directory | `700` |
| `~/.deep-finder/cache/index.db` | SQLite WAL index database (FileRecord storage) | `600` |

### `logs/` -- Diagnostic Logs

Per-launch log files for debugging. The daemon and GUI each write their own log on every start.

| Path | Purpose | Permissions |
|------|---------|-------------|
| `~/.deep-finder/logs/` | Logs directory | `700` |
| `~/.deep-finder/logs/gui-<timestamp>.log` | GUI app stderr log (one file per launch) | `600` |

## Other Paths

| Path | Purpose |
|------|---------|
| `~/Library/LaunchAgents/cn.com.nadav.deepfinder.daemon.plist` | LaunchAgent plist for auto-start on login. Installed by `deepfinder install`, removed by `deepfinder uninstall`. |

## Why These Paths Exist

For the architectural rationale behind this directory layout -- why the daemon holds an in-memory index, why there is a Unix socket, why paths are encrypted in SQLite -- see the [Architecture](../explanation/architecture.md) explanation.
