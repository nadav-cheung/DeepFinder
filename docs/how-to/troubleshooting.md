# Troubleshooting

This guide is organized by **symptom** -- find the heading that matches what you are experiencing, then work through the fixes in order.

## DeepFinder Can't Find My Files

Search returns no results or is missing files you know exist.

1. **Full Disk Access not granted** -- DeepFinder needs Full Disk Access to index protected directories (~/Documents, ~/Desktop, ~/Downloads). Go to **System Settings > Privacy & Security > Full Disk Access** and toggle DeepFinder (or the `deepfinder-daemon` binary) ON. If it is already on, toggle it OFF, wait a few seconds, then toggle it ON again.
2. **Path in excludedPaths** -- You may have excluded the directory where those files live. Run `deepfinder config get excludedPaths` to check. If the path appears there, remove it with `deepfinder config set excludedPaths --remove /path/to/dir`.
3. **Index is stale** -- The index can get out of sync after unexpected daemon shutdowns or filesystem errors. Rebuild it by stopping the daemon, deleting the cache, and restarting:
   ```bash
   deepfinder daemon stop
   rm ~/.deep-finder/cache/index.db
   deepfinder daemon start
   ```

If this didn't help, [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any error output.

## Daemon Won't Start

The daemon refuses to start, or CLI commands show "daemon not running" / connection refused.

1. **Stale socket file** -- If the daemon crashed without cleaning up, a stale socket file blocks the next start. Remove it: `rm ~/.deep-finder/session/ipc.sock`. Then restart the daemon with `deepfinder daemon start`.
2. **launchd conflict** -- A stale LaunchAgent registration may be holding a reference. Check with `launchctl list | grep deepfinder`. If a stale entry exists, unload it: `launchctl unload ~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist`, then restart.
3. **Permission denied on data directory** -- The daemon needs read/write access to `~/.deep-finder`. Ensure correct permissions: `chmod 700 ~/.deep-finder` and verify the directory is owned by your user: `ls -ld ~/.deep-finder`.

If this didn't help, [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any error output.

## Search Is Slow

Queries that are normally instant take noticeably longer.

1. **Index is rebuilding** -- After a rebuild or large batch of filesystem changes, the index may be catching up. Run `deepfinder :stats` (in REPL) to check the index state. If it says `verifying` or `stale`, wait for it to reach `live`.
2. **External volume mounted** -- External drives (especially network volumes or slow USB disks) add latency. Check active volumes with `deepfinder daemon status`. Unmount unnecessary volumes or add slow paths to `excludedPaths`.
3. **AI search timeout** -- If you are using AI semantic search (v3.0+), network latency to the AI provider can slow things down. Verify connectivity (`curl https://api.deepseek.com` or your provider's endpoint).

If this didn't help, [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any error output.

## Hotkey Doesn't Work

The global hotkey (default: Control-Command-K) does not bring up the search panel.

1. **Accessibility permission not granted** -- Global hotkeys require Accessibility access. Go to **System Settings > Privacy & Security > Accessibility** and ensure DeepFinder is enabled. If it is listed but not working, remove it, then add it again.
2. **Conflict with another app** -- Another application may have registered the same shortcut. Try a different hotkey via the GUI settings panel. Restart the GUI app after changing.
3. **CGEventTap failure** -- In rare cases, the system event tap used as a fallback for hotkey registration fails. Restart the DeepFinder app (quit from menu bar icon and relaunch).

If this didn't help, use the menu bar icon to open the search panel, then [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any error output.

## AI Features Not Working

Semantic search, image similarity, or other AI-powered features return errors or silently fall back.

1. **API key not configured** -- Each AI provider needs its API key configured. Run `deepfinder ai setup` and follow the interactive prompts to configure your preferred provider. API keys are stored securely in `~/.deep-finder/secrets.json` (permissions 600).
2. **Network issue** -- The AI provider may be unreachable. Test connectivity: `curl -I https://api.deepseek.com` (or your provider's endpoint). Check your firewall, VPN, or proxy settings if the connection fails.
3. **Quota exhausted** -- Your API account may have hit its usage limit. Check your provider's dashboard (DeepSeek console, Anthropic Console, OpenAI Platform, etc.) for billing status and rate limits.

AI features degrade gracefully -- if the AI provider is unavailable, DeepFinder falls back to plain text search automatically.

If this didn't help, [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any error output.

## High Resource Usage

The daemon is consuming excessive CPU or memory.

1. **Index size vs. expectations** -- Check `deepfinder daemon status` (or `:stats` in REPL) for the file count. ~200 MB for 500K files is normal. If you have 2M+ files, proportionally higher memory is expected. If usage is far above the norm for your file count, the index may be bloated with noise.
2. **Exclude noise directories** -- Large directories of tiny files (`node_modules`, build output, caches) inflate both index size and scan CPU. Add them to `excludedPaths`: `deepfinder config set excludedPaths '["/System","/Library","/Users/you/Projects"]'`. Or use `.deepfinderignore` for per-project control.
3. **FSEvents storm** -- If a directory is being modified rapidly (e.g., a log rotator or build watcher), FSEvents may generate excessive events. Identify the source with `deepfinder daemon status` (watch the file count trend). Exclude the noisy directory temporarily, then investigate.

If this didn't help, [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and a sample of your Activity Monitor output.

## Index Is Stuck or Never Completes

The daemon is running but the index stays in `verifying` or `stale` state indefinitely, or the file count never reaches the expected number.

1. **Full Disk Access missing** -- If the daemon cannot access protected directories, it will scan what it can reach and appear stuck. Verify Full Disk Access is granted. Toggle it OFF and ON again to force re-evaluation.
2. **Unmountable volume** -- A network share or external drive that is slow to respond can block the scanner. Check with `deepfinder daemon status` for any volumes listed that are unresponsive. Unmount or exclude the problematic volume.
3. **Force a rebuild** -- Stop the daemon, delete the index cache, and restart to force a full re-scan:
   ```bash
   deepfinder daemon stop
   rm ~/.deep-finder/cache/index.db
   deepfinder daemon start
   ```
   This resolves most stuck-index scenarios.
4. **Permission error on a specific directory** -- A single unreadable directory can stall the scanner. Check Console.app for `deepfinder-daemon` error messages referencing specific paths, then either fix permissions or exclude that path.

If this didn't help, [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any relevant Console.app log excerpts.

## Install Problems

Installation via Homebrew, DMG, or from source fails.

1. **Homebrew formula not found (404)** -- The formula index may be out of date. Run `brew update` and try again. If it still fails, the tap may need to be re-added: `brew tap nadav/homebrew-deepfinder && brew install deepfinder`.
2. **Code signature verification failed** -- macOS Gatekeeper may block an unsigned or tampered binary. Download from the official [GitHub Releases](https://github.com/nadav-cheung/DeepFinder/releases) page and verify the SHA-256 checksum listed there. Do not bypass Gatekeeper unless you have verified the checksum.
3. **macOS version too old** -- DeepFinder requires **macOS 26 (Tahoe)** or later. Check your version: `sw_vers -productVersion`. If you are on an older version, upgrade macOS first.

If this didn't help, download the DMG directly from [GitHub Releases](https://github.com/nadav-cheung/DeepFinder/releases), or [open an issue](../SUPPORT.md) and include your daemon status (`deepfinder daemon status`) and any error output.
