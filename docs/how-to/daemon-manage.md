# Manage the Daemon

## You want to manage the background daemon

The DeepFinder daemon runs in the background, holding the entire file index in memory for sub-millisecond queries. You can start, stop, restart, check status, and rebuild the index without leaving the terminal.

### Start the daemon

If the daemon is not running, start it:

```bash
deepfinder daemon start
```

You do not usually need this -- the daemon starts automatically the first time you run a query (`deepfinder "something"`).

If a previous daemon crashed and left stale files behind, `start` cleans them up automatically before launching.

### Stop the daemon

```bash
deepfinder daemon stop
```

This sends SIGTERM to the daemon. The daemon flushes pending writes to the SQLite index, removes its socket file, and exits. Give it a moment -- if it does not shut down within 5 seconds, you can force-kill it:

```bash
kill -9 <PID>
```

You can find the PID with `deepfinder daemon status` or by reading `~/.deep-finder/session/daemon.pid`.

### Restart the daemon

```bash
deepfinder daemon restart
```

This stops the daemon if it is running, then starts a fresh one. The new daemon reloads the index from the SQLite cache on disk, which takes a few seconds. Use this after changing configuration that affects indexing, or if the daemon seems stuck.

### Check daemon status

```bash
deepfinder daemon status
```

Shows the daemon's PID, uptime, index state (stale / verifying / live), file count, and approximate memory usage. Example output:

```
Daemon: running
PID: 84291
Uptime: 2h 14m
Index state: live
Files indexed: 482,391
Memory: 342 MB
```

If nothing is running, it reports "Daemon: not running."

### Rebuild the index

```bash
deepfinder daemon rebuild
```

This wipes the on-disk SQLite cache and rescans the entire filesystem from scratch. Use it when:

- The index seems out of sync with the actual filesystem
- You suspect index corruption
- You changed excluded paths and want a clean baseline

The rebuild runs in the background. You can search while it is in progress -- results appear as files are indexed. Check progress with `deepfinder daemon status`.

### Auto-start on login (LaunchAgent)

To have the daemon start automatically when you log in, install the LaunchAgent:

```bash
deepfinder install
```

This creates `~/Library/LaunchAgents/com.nadav.deepfinder.plist`. macOS launchd picks it up on next login, or you can load it immediately:

```bash
launchctl load ~/Library/LaunchAgents/com.nadav.deepfinder.plist
```

To remove the auto-start behavior:

```bash
deepfinder uninstall
```

This removes the plist and unloads it from launchd if currently loaded.

### File paths used by the daemon

| Path | Purpose |
|------|---------|
| `~/.deep-finder/session/daemon.pid` | Running daemon PID |
| `~/.deep-finder/session/ipc.sock` | Unix domain socket for CLI/GUI communication |
| `~/.deep-finder/cache/index.db` | SQLite WAL index database |
| `~/Library/LaunchAgents/com.nadav.deepfinder.plist` | LaunchAgent plist (auto-start) |

### Crash recovery

If the daemon crashes or is killed (e.g., `kill -9`), it may leave behind a stale PID file and socket:

```bash
# Diagnose the problem
deepfinder daemon status
# → "Daemon: not running" but PID file exists -- stale files

# Fix it: the next start cleans up automatically
deepfinder daemon start
```

The `daemon start` command checks whether the PID in `daemon.pid` belongs to a live process. If not, it removes the stale PID file and socket before starting a fresh daemon.

A daemon crash does not lose your index -- the data is persisted in SQLite at `~/.deep-finder/cache/index.db`. The new daemon reloads it on startup.

---

**Did this help?** If you are troubleshooting a problem, see [Troubleshooting](troubleshooting.md). If you are stuck, [get help](../SUPPORT.md).

**Next steps:**

| You want to... | Read this |
|---------------|-----------|
| Configure excluded paths or other settings | [Configure DeepFinder](configure.md) |
| Understand why DeepFinder uses a daemon | [How DeepFinder Works](../explanation/architecture.md) |
| See where every file lives on disk | [File Paths Reference](../reference/file-paths.md) |
| Look up configuration key defaults | [Configuration Reference](../reference/config-keys.md) |
| Fix common problems | [Troubleshooting](troubleshooting.md) |
