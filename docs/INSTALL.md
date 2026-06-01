# DeepFinder Installation Guide

## Prerequisites

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| macOS | 26 (Tahoe) | Xcode 26+ required for build-from-source |
| Architecture | Apple Silicon (arm64) | M4 or later. Intel not supported |
| Permissions | Full Disk Access | Required for indexing all directories |
| Swift toolchain | 6.2+ | Included with Xcode 26+ |

## Install Methods

### From Source (Recommended)

Build and install from source. This is the primary distribution method.

```bash
# Clone the repository
git clone https://github.com/nadav/deep-finder.git
cd deep-finder

# Build release binary
swift build -c release

# Install to /usr/local/bin
sudo cp .build/release/deepfinder /usr/local/bin/
sudo cp .build/release/deepfinder-daemon /usr/local/bin/
```

Verify the installation:

```bash
deepfinder --version
# Expected: DeepFinder v3.0.0
```

### Homebrew (Future)

Homebrew distribution will be available post v1.0 release.

```bash
# Will be available as:
brew tap nadav/tap
brew install deepfinder

# Verify
deepfinder --version
```

## Full Disk Access Setup

DeepFinder indexes files across your entire home directory and shared system directories. This requires Full Disk Access from macOS.

### Step-by-Step

1. Open **System Settings** from the Apple menu or Dock.
2. Navigate to **Privacy & Security** in the sidebar.
3. Select **Full Disk Access** from the list of permissions.
4. Click the **+** button at the bottom of the application list.
5. In the file browser that appears, type `Cmd+Shift+G` and enter `/usr/local/bin/`.
6. Select `deepfinder-daemon` and click **Open**.
7. Verify the toggle next to `deepfinder-daemon` is enabled (blue/on).

If you installed to a different location, navigate to that directory in step 5.

### Why Full Disk Access?

Without Full Disk Access, macOS silently hides files in protected directories:

| Directory | Population Impact |
|-----------|-------------------|
| `~/Documents` | All user documents |
| `~/Desktop` | All desktop files |
| `~/Downloads` | All downloads |
| `~/Photos` | All photos |
| Mail, Messages, Contacts | App data directories |

Without Full Disk Access, search results are incomplete and silently missing files from these critical locations. DeepFinder does not send any data off your Mac -- Full Disk Access is used exclusively for local indexing.

### Verification

After granting permission, verify index coverage:

```bash
deepfinder daemon rebuild
deepfinder :stats
# Check indexedFiles count matches `find ~ -type f | wc -l` approximately
```

## LaunchAgent Setup (Auto-Start on Login)

The daemon can be installed as a LaunchAgent to start automatically when you log in.

```bash
# Install the LaunchAgent
deepfinder daemon install

# Verify it is loaded
launchctl list | grep deepfinder
```

The LaunchAgent starts the daemon at login and keeps it running (`KeepAlive`). Logs are written to:

| Stream | Path |
|--------|------|
| stdout | `/tmp/deepfinder-daemon.log` |
| stderr | `/tmp/deepfinder-daemon.err` |

### Manual LaunchAgent Management

```bash
# Stop the daemon and unload the LaunchAgent
deepfinder daemon uninstall

# Start the daemon manually (not via LaunchAgent)
deepfinder daemon start

# Stop a running daemon
deepfinder daemon stop

# Restart
deepfinder daemon restart
```

### LaunchAgent plist Reference

The generated plist is located at `~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nadav.deepfinder.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/deepfinder</string>
        <string>daemon</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/deepfinder-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/deepfinder-daemon.err</string>
</dict>
</plist>
```

## Verification

### Check Version

```bash
deepfinder --version
# Expected: DeepFinder v3.0.0
```

### Check Daemon Status

```bash
deepfinder daemon status
# Expected output:
#   State:        live
#   Indexed files: 1,234,567
#   Uptime:        2h 15m
#   Memory:        4.2 GB
#   Daemon PID:    12345
```

### Run a Test Search

```bash
deepfinder "README"
# Should return results instantly
```

### Verify Full Disk Access Coverage

```bash
# Count files in your home directory
find ~ -type f 2>/dev/null | wc -l

# Compare with DeepFinder's indexed count
deepfinder daemon status | grep "Indexed files"
```

The indexed count should be within roughly 2-5% of the `find` count. Differences are expected: DeepFinder excludes `.Trash`, `node_modules`, and other configurable paths.

### GUI Verification (v2.0+)

Launch the app and press `Ctrl+Cmd+K` from any application. The search panel should appear at the top-center of your screen.

The GUI requires **Accessibility** permission for the global hotkey:

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Enable the toggle for **DeepFinder**.

## Troubleshooting

### Daemon Fails to Start

**Symptom:** `deepfinder daemon status` shows `error` or `Connection refused`.

**Cause (1): Stale socket file.** If the daemon crashed without cleanup, the stale socket file at `~/.deep-finder/ipc.sock` blocks startup.

**Fix:**

```bash
# Check if the daemon is actually running
ps aux | grep deepfinder-daemon

# If not running, remove the stale socket
rm ~/.deep-finder/ipc.sock

# Start the daemon again
deepfinder daemon start
```

**Cause (2): Port/address already in use.** Another process is bound to the socket path.

**Fix:**

```bash
# Check what is using the socket
lsof ~/.deep-finder/ipc.sock

# If it is a stale/zombie process, kill it
kill -9 <PID>
rm ~/.deep-finder/ipc.sock
deepfinder daemon start
```

### Daemon Crash Recovery

**Symptom:** Queries fail mid-session with `Connection lost` or `Broken pipe`.

**Fix:**

```bash
# The CLI auto-reconnects on next query.
# If it does not, manually restart:
deepfinder daemon restart

# Check logs for crash cause
tail -100 /tmp/deepfinder-daemon.err
```

Common crash causes:
- Out of memory (rare on M4+ -- check `deepfinder daemon status` for memory usage)
- Corrupt SQLite database (see Database Corruption below)
- SIGTERM from system (check Console.app for jetsam events)

### Database Corruption

**Symptom:** Daemon starts but `deepfinder daemon status` shows `stale` indefinitely, or errors about SQLite.

**Fix:**

```bash
# Remove the corrupted index and rebuild
deepfinder daemon stop
rm ~/.deep-finder/index.db
deepfinder daemon start
# Daemon will perform a full re-index (may take several minutes)
```

### Permission Denied

**Symptom:** `Permission denied` when running `deepfinder` or `deepfinder-daemon`.

**Fix:**

```bash
# Verify executables have correct permissions
ls -la /usr/local/bin/deepfinder*
# Expected: -rwxr-xr-x

# Fix if needed
chmod 755 /usr/local/bin/deepfinder
chmod 755 /usr/local/bin/deepfinder-daemon
```

**Symptom:** `FSEventStream failed to start` or similar FSEvents errors.

**Fix:** Ensure Full Disk Access is granted (see Full Disk Access Setup above). Without it, FSEvents cannot monitor protected directories.

### No Search Results

**Symptom:** Daemon reports `live` state but queries return no results.

**Checks:**

1. Verify index state:
   ```bash
   deepfinder daemon status
   # State must be "live", indexedFiles must be > 0
   ```

2. If `indexedFiles` is 0 or very low, rebuild:
   ```bash
   deepfinder daemon rebuild
   ```

3. Check excluded paths:
   ```bash
   deepfinder config get excludePaths
   # Ensure nothing critical is excluded
   ```

4. Verify Full Disk Access is enabled for the daemon.

### GUI Hotkey Not Working

**Symptom:** `Ctrl+Cmd+K` does nothing.

**Fix:**

1. Verify Accessibility permission is granted:
   - **System Settings** > **Privacy & Security** > **Accessibility**
   - Toggle **DeepFinder** on.

2. Check for hotkey conflicts:
   ```bash
   # The GUI logs hotkey registration results
   tail -50 /tmp/deepfinder-gui.log
   ```

3. If another app has claimed `Ctrl+Cmd+K`, change the hotkey:
   ```bash
   deepfinder config set hotKey "Ctrl+Cmd+Space"
   ```

### LaunchAgent Not Starting on Login

**Symptom:** Daemon does not auto-start after logout/login.

**Fix:**

```bash
# Check LaunchAgent status
launchctl list | grep deepfinder

# If not present, re-install
deepfinder daemon uninstall
deepfinder daemon install

# Check plist syntax
plutil -lint ~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist

# Manually load for testing
launchctl load ~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist
```

### High Memory Usage

**Symptom:** Activity Monitor shows `deepfinder-daemon` consuming excessive memory.

**Context:** The FullSubstringMap for 1M files uses approximately 8-10 GB of memory by design (speed over memory on M4+). If memory usage exceeds this, check:

```bash
# Check index stats
deepfinder :stats

# If indexedFiles is significantly above 1M, adjust max memory limit:
deepfinder config set maxMemoryGB 16
```

If your system is under memory pressure, the daemon will automatically degrade from FullSubstringMap to TrigramIndex to reduce footprint:

```bash
deepfinder config set substringMapEnabled false
```

This reduces memory usage at the cost of slightly slower substring queries.

## Uninstall

### Full Uninstall

```bash
# 1. Stop and remove the LaunchAgent
deepfinder daemon uninstall

# 2. Stop the running daemon
deepfinder daemon stop

# 3. Remove binaries
sudo rm /usr/local/bin/deepfinder
sudo rm /usr/local/bin/deepfinder-daemon

# 4. Remove data directory
rm -rf ~/.deep-finder

# 5. Remove build artifacts (if built from source)
# Navigate to the source directory and:
cd /path/to/deep-finder
rm -rf .build
```

### Remove Data Only (Keep Binaries)

```bash
# Stop daemon, remove data, restart -- triggers full re-index
deepfinder daemon stop
rm -rf ~/.deep-finder
deepfinder daemon start
```

## Data Directory Reference

All DeepFinder runtime data lives under `~/.deep-finder/`:

| Path | Purpose | Safe to Delete? |
|------|---------|-----------------|
| `~/.deep-finder/index.db` | SQLite WAL database (FileRecord storage) | Yes -- triggers full re-index |
| `~/.deep-finder/index.db-wal` | SQLite write-ahead log | Deleted with index.db |
| `~/.deep-finder/index.db-shm` | SQLite shared memory | Deleted with index.db |
| `~/.deep-finder/config.json` | User configuration | Yes -- reverts to defaults |
| `~/.deep-finder/ipc.sock` | Unix domain socket (daemon running) | Only when daemon is stopped |
| `~/.deep-finder/daemon.pid` | Daemon PID file | Only when daemon is stopped |
| `~/.deep-finder/history` | REPL command history | Yes -- search history lost |
| `~/.deep-finder/log/` | Daemon runtime logs | Yes -- old logs only |

Directory permissions are `700` (owner-only access). All files are `600` (owner-only read/write).
