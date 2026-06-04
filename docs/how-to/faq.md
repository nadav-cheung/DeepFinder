# Frequently Asked Questions

## How is DeepFinder different from Spotlight?

DeepFinder builds and maintains its **own index**, completely independent of
Spotlight. Spotlight uses Apple's system index (mds/mdworker), which means every
tool that relies on it -- Alfred, Raycast, HoudahSpot -- inherits every
Spotlight failure mode.

Spotlight's four most common failure modes, and what DeepFinder does about each:

1. **Index corruption requiring `mdutil -E` rebuilds (can take hours).**
   Spotlight's index database can become corrupt after crashes, forced reboots,
   or disk errors, requiring a full rebuild that blocks all Spotlight-dependent
   apps. DeepFinder's index is an in-memory structure backed by a SQLite WAL
   store -- it never needs a "full rebuild" from scratch and recovers in under a
   second on restart.

2. **Silently skipping files without notification.**
   Spotlight has exclusion lists that are not user-visible -- certain directory
   trees and file types are skipped entirely, with no indication to the user.
   DeepFinder indexes every file on every mounted volume by default. If a path
   is excluded, it is because you explicitly added it to `excludedPaths` in your
   config.

3. **No index health visibility.**
   Spotlight gives you no way to know whether its index is complete, stale, or
   missing directories. DeepFinder shows real-time index status via `:stats` in
   the REPL -- file count, scan progress, and index state (stale / verifying /
   live).

4. **Fragility across macOS upgrades.**
   Major macOS upgrades frequently change Spotlight internals, breaking
   dependent tools until they ship updates. DeepFinder uses only stable public
   APIs (FSEvents, SQLite3, Foundation) and does not depend on any
   Apple-proprietary index format.

For a detailed side-by-side comparison with every major macOS search tool, see
[DeepFinder vs. The Alternatives](../COMPARISON.md).

## Why can't DeepFinder find some of my files?

There are three common causes, in order of likelihood:

1. **Full Disk Access not granted (most common).**
   DeepFinder needs Full Disk Access to index protected directories like
   `~/Documents`, `~/Desktop`, and `~/Downloads`. Without it, FSEvents silently
   skips these locations. Check **System Settings > Privacy & Security > Full
   Disk Access** and make sure DeepFinder (or the daemon) is enabled.

2. **Paths in `excludedPaths` config.**
   Run `deepfinder config get excludedPaths` to see which directories are
   excluded. If the missing files live under one of those paths, remove it:
   ```bash
   deepfinder config set excludedPaths '["/System","/Library"]'
   ```

3. **Stale index.**
   If the daemon has been paused or crashed, the in-memory index may not reflect
   recent filesystem changes. Rebuild the index from scratch:
   ```bash
   deepfinder daemon stop
   rm ~/.deep-finder/cache/index.db
   deepfinder daemon start
   ```

## The global hotkey doesn't work. What should I do?

The default global hotkey is **Control-Command-K** (⌃⌘K). If pressing it does
nothing, check these three things:

1. **Accessibility permission.**
   DeepFinder needs Accessibility permission to register a global hotkey. Go to
   **System Settings > Privacy & Security > Accessibility** and enable
   DeepFinder.

2. **Conflict with another app.**
   If another app has already registered ⌃⌘K, DeepFinder cannot claim it. Try
   changing the hotkey in DeepFinder's Settings panel, or quit the conflicting
   app and try again.

3. **CGEventTap failure.**
   DeepFinder falls back to CGEventTap when `RegisterEventHotKey` is
   unavailable. Some macOS security configurations block CGEventTap. If neither
   method works, restarting the app after granting Accessibility permission
   usually resolves the issue.

## How do I exclude directories like node_modules or .git?

Use the `config set` command to add paths to the `excludedPaths` list:

```bash
deepfinder config set excludedPaths '["/System","/Library","/Users/nadav/Projects"]'
```

Note: many common noise directories are handled by DeepFinder's smart
filtering -- files inside `.git/` directories and other VCS internals are
de-prioritized in results by default. But if you want to exclude them from the
index entirely (saving memory and scan time), add their parent directories to
`excludedPaths`.

For volumes you want to skip (e.g. Time Machine drives), use `excludedVolumes`:

```bash
deepfinder config set excludedVolumes '["/Volumes/Time Machine"]'
```

See the [configuration guide](configure.md) for all available settings.

## Do AI features require internet? Which are local?

Some AI features run entirely on-device; others require cloud API access.

| Feature | Runtime | Notes |
|---------|---------|-------|
| Natural language translation | Cloud | Converts "find my tax pdf from last week" into search queries |
| Semantic suggestions | Cloud | Ranks results by relevance to your query intent |
| Summarization | Cloud | Summarizes file contents in search results |
| Intent analysis | Cloud | Understands complex search intent |
| File operations | Cloud | "Move my screenshots to a folder named 2025" |
| Vision tagging | Local | On-device image content classification via CoreML |
| Speech input | Local | On-device speech-to-text via Apple Speech framework |
| Clipboard search | Local | Searches clipboard history, never leaves the device |
| Match explanation | Local | Explains why a result matched your query |

**Cloud features require an API key.** DeepFinder supports Anthropic, OpenAI,
DeepSeek, Gemini, Qwen, and any OpenAI-compatible endpoint. Enable AI and configure
your provider:
```bash
deepfinder config set ai.enabled true
deepfinder config set ai.model deepseek
deepfinder config set ai.apiKey "sk-..."
```
No data is sent to cloud providers unless you enable cloud AI features and supply an API
key.

## How do I use DeepFinder results in scripts?

DeepFinder provides two structured output modes designed for scripting:

**`--json`** -- emits results as a JSON array. Pipe through `jq` for filtering
and transformation:

```bash
deepfinder --json "tax return" | jq '.[] | .path'
deepfinder --json "*.swift" | jq '.[] | {name: .name, size: .fileSize}'
```

**`--0`** -- emits file paths separated by null bytes, safe for paths containing
spaces. Pipe through `xargs` for batch operations:

```bash
deepfinder --0 "*.log" | xargs -0 rm
deepfinder --0 "*.mp4" | xargs -0 -I{} mv {} ~/Videos/
```

For full coverage including exit codes, control flow, and the HTTP API, see the
[scripting guide](scripting.md).

## The daemon won't connect. How do I fix it?

Three things to check, from most to least common:

1. **Stale socket file.**
   If the daemon crashes without cleanup, the Unix socket file at
   `~/.deep-finder/session/ipc.sock` can block a new daemon from starting.
   Remove it manually:
   ```bash
   rm ~/.deep-finder/session/ipc.sock
   ```

2. **Daemon not running.**
   Check status and start if needed:
   ```bash
   deepfinder daemon status
   deepfinder daemon start
   ```

3. **Port conflict or permission issue.**
   The socket path must be writable by your user. If `~/.deep-finder/session/`
   has incorrect permissions, fix with:
   ```bash
   chmod 700 ~/.deep-finder/session
   ```

## How do I migrate DeepFinder to a new Mac?

1. Install DeepFinder on the new Mac:
   ```bash
   brew install nadav/deepfinder/deepfinder
   ```

2. (Optional) Copy your config file:
   ```bash
   scp old-mac:~/.deep-finder/settings.json ~/.deep-finder/settings.json
   ```

3. The index rebuilds automatically on first launch -- no manual steps required.
   Indexing time depends on your file count; on M4 it typically completes in
   under 30 seconds for 500K files.

## How much memory does the index use?

Approximately **200 MB for 500,000 files** on Apple Silicon (M4). Memory usage
scales roughly linearly with file count: ~400 MB for 1 million files, ~80 MB for
200,000 files. The index is held entirely in unified memory for sub-millisecond
query latency.

You can check current usage at any time:

```bash
deepfinder :stats
```

## How do I uninstall DeepFinder?

```bash
brew uninstall deepfinder
rm -rf ~/.deep-finder/
launchctl unload ~/Library/LaunchAgents/cn.com.nadav.deepfinder.daemon.plist
rm ~/Library/LaunchAgents/cn.com.nadav.deepfinder.daemon.plist
```

This removes the binary, all index and config data, and the LaunchAgent that
auto-starts the daemon on login.

---

Still have questions? See [Support](../SUPPORT.md).
