# DeepFinder Onboarding Guide

This guide walks you through setting up DeepFinder for the first time. The order matters -- complete each step before moving to the next.

**Prerequisites**: DeepFinder installed. If you have not installed it yet, follow the [Installation Guide](../INSTALL.md) first.

**Estimated time**: 3-5 minutes.

---

## Table of Contents

1. [Step 0: Welcome -- What DeepFinder Is (and Isn't)](#step-0-welcome----what-deepfinder-is-and-isnt)
2. [Step 1: Full Disk Access -- This Must Come First](#step-1-full-disk-access----this-must-come-first)
3. [Step 2: Index Scope -- See What Gets Indexed](#step-2-index-scope----see-what-gets-indexed)
4. [Step 3: Accessibility (Hotkey) -- Optional Convenience](#step-3-accessibility-hotkey----optional-convenience)
5. [Step 4: AI Setup -- Opt-In Privacy-First Intelligence](#step-4-ai-setup----opt-in-privacy-first-intelligence)
6. [Step 5: First Search -- Your Aha Moment](#step-5-first-search----your-aha-moment)
7. [Permission Diagnostics](#permission-diagnostics)
8. [Trust Building: What's Indexed and What's Not](#trust-building-whats-indexed-and-whats-not)
9. [Error Recovery](#error-recovery)
10. [Onboarding Checklist](#onboarding-checklist)
11. [Screenshot Specifications](#screenshot-specifications)

---

## Step 0: Welcome -- What DeepFinder Is (and Isn't)

### What DeepFinder Is

DeepFinder is a file search engine that **builds its own index** of every file on your Mac. It does not rely on Spotlight. It does not call home. It works offline, locally, at memory speed.

- **Instant**: Searches complete in under 100 milliseconds. The entire file index lives in RAM.
- **Complete**: Indexes every directory you give it access to -- no silent gaps, no "Spotlight didn't index that folder."
- **Private**: All data stays on your Mac. No telemetry. No cloud sync. No analytics.
- **Free and open source**: No paid tiers. No subscriptions. Source code at [github.com/nadav-cheung/DeepFinder](https://github.com/nadav-cheung/DeepFinder).

### What DeepFinder Is Not

- **Not a Spotlight replacement**: Spotlight is a system service Apple controls. DeepFinder is an independent index you control.
- **Not a launcher**: It searches files, not apps, contacts, or web bookmarks.
- **Not a cloud service**: It does not upload your files anywhere. See the [Privacy Model](../explanation/privacy-model.md) for details.
- **Not for Intel Macs**: Requires Apple Silicon (M4 or later) and macOS 26 (Tahoe).

### Why This Matters

Spotlight is convenient but **unreliable**. Apple controls what it indexes, when it re-indexes, and which directories it silently skips. Many macOS users have experienced the frustration of searching for a file they know exists -- only to get zero results. DeepFinder solves this by giving you **full control** over what gets indexed and **complete transparency** into what does not.

**The single most important decision you make during setup is granting Full Disk Access.** Without it, DeepFinder cannot see files in your most important directories. Let's do that first.

> **Screenshot 0**: Welcome window showing the DeepFinder icon, product name, and the three value propositions above. Clean, minimal, no feature cards -- just the elevator pitch and a prominent "Get Started" button.

---

## Step 1: Full Disk Access -- This Must Come First

### Why Full Disk Access Comes Before Everything Else

macOS protects certain directories from applications by default. Without Full Disk Access (FDA), DeepFinder **cannot see** files in these locations:

| Directory | What's In There | Impact If Missing |
|-----------|-----------------|-------------------|
| `~/Documents` | Your documents, spreadsheets, PDFs, notes | Most of your work files are invisible |
| `~/Desktop` | Files you keep on your desktop | Desktop files silently omitted from results |
| `~/Downloads` | Every file you have ever downloaded | Download folder is a black hole |
| `~/Photos` | Your Photos library | All photos absent from search |
| `~/Mail` | Apple Mail data | Cannot search mail attachments |
| `~/Messages` | iMessage attachments | Cannot search message attachments |

**This is not a DeepFinder limitation -- it is macOS security policy.** Every app that needs to read files in these directories requires Full Disk Access. The difference is that DeepFinder **tells you** when coverage is incomplete, while Spotlight and other tools stay silent.

### The Trust Crisis We Are Preventing

If you skip Full Disk Access and start searching, here is what happens:

1. You search for `budget-2026.xlsx`, a file you know is in `~/Documents`.
2. DeepFinder returns **zero results**.
3. You conclude DeepFinder is broken.
4. You uninstall.

**This is the number one reason users abandon file search tools.** We prevent it by making Full Disk Access the first and most important setup step.

### How to Grant Full Disk Access

1. Open **System Settings** from the Apple menu () or Dock.
2. Click **Privacy & Security** in the sidebar.
3. Scroll down and select **Full Disk Access**.
4. If DeepFinder is already listed, toggle it **ON**. If not:
   - Click the **+** button.
   - In the file browser, press **Cmd+Shift+G** and enter `/opt/homebrew/bin/`.
   - Select `deepfinder-daemon` and click **Open**.
   - Toggle the switch to **ON** (blue).
5. Close System Settings.

> **Screenshot 1a**: System Settings > Privacy & Security > Full Disk Access pane, with the `deepfinder-daemon` entry highlighted and the toggle in the ON position. Annotate with a red arrow pointing to the toggle.
>
> **Screenshot 1b**: The file browser dialog (after clicking +) with the path `/opt/homebrew/bin/` entered in the Go-to-folder field (Cmd+Shift+G), showing `deepfinder-daemon` selected.

### Verification

After granting Full Disk Access, verify it is working:

```bash
deepfinder daemon status
```

Look for:
- **State**: `live` (not `stale` or `verifying`)
- **Indexed files**: A number that is roughly close to `find ~ -type f 2>/dev/null | wc -l`

If the indexed file count is significantly lower than expected, Full Disk Access may not be active. See [Permission Diagnostics](#permission-diagnostics) below.

### What We Do With Full Disk Access

- Read file names, paths, sizes, and modification dates to build the search index.
- Monitor file changes via FSEvents so the index stays current.
- That is it. We do not read file contents during indexing (content search is on-demand and opt-in only). We do not transmit any data off your Mac.

### What We Never Do

- Read file contents without your explicit action (content search).
- Upload any data to any server.
- Share anything with Apple, app analytics, or third parties.
- Store anything outside `~/.deep-finder/` (permissions 700, only your user can read it).

> **Trust note**: You can revoke Full Disk Access at any time via System Settings. DeepFinder will detect the loss and show a warning in search results. See [Error Recovery](#error-recovery) for what happens after macOS updates.

---

## Step 2: Index Scope -- See What Gets Indexed

### What Gets Indexed by Default

With Full Disk Access granted, DeepFinder indexes:

- Your entire home directory (`/Users/you/`)
- Any mounted external or network volumes

**Default exclusions** (these are always skipped, for performance and relevance):

| Path | Reason |
|------|--------|
| `~/.Trash/` | Trash contents are not searchable |
| `/System/` | System files -- not user data |
| `~/.deep-finder/` | DeepFinder's own data directory |
| `node_modules/` | Dependency directories -- massive, rarely searched |
| `.git/` | Git internals -- not user files |

### Customize Exclusions

You can exclude additional directories to reduce index size and noise:

```bash
# Add an exclusion
deepfinder config set excludedPaths --add ~/Projects/build

# Add multiple exclusions
deepfinder config set excludedPaths --add ~/Library/Caches --add ~/VirtualMachines

# View current exclusions
deepfinder config get excludedPaths

# Remove an exclusion
deepfinder config set excludedPaths --remove ~/Projects/build
```

Common directories worth excluding:
- `~/Library/Caches` -- app caches, regenerated automatically
- `~/VirtualMachines` -- VM disk images are large and unsearchable
- Build output directories (`DerivedData`, `target/`, `dist/`, `build/`)

### Use `.deepfinderignore` for Per-Project Control

Place a `.deepfinderignore` file in any directory to exclude its contents. Syntax is the same as `.gitignore`:

```
# Example: ~/Projects/my-website/.deepfinderignore
node_modules/
.next/
dist/
*.log
```

This is useful for project-specific exclusions without modifying global config.

### Understanding Index Coverage

DeepFinder displays index coverage as a health indicator:

```
DeepFinder daemon status:
  State: live
  Indexed files: 1,234,567
  Volumes: Macintosh HD, External SSD
  Coverage: 98.2% (estimated)
  Last full scan: 2026-06-03 09:15:32
  Skipped: 23,456 files (in 12 excluded directories)
```

The **Coverage** percentage compares indexed files against an estimate of total user-accessible files on your volumes. It is an approximation, not an exact count -- system files and unreadable paths are factored out. If coverage drops below 90%, check your Full Disk Access and exclusion settings.

> **Screenshot 2**: The daemon status output or a GUI equivalent showing index health with coverage percentage, file count, and excluded directory count. Highlight the coverage line.

---

## Step 3: Accessibility (Hotkey) -- Optional Convenience

### This Is Optional

The Accessibility permission is **only needed for the global hotkey** (default: Control-Command-K). It is **not required for search**. If you skip this step:

- You can still search via the menu bar icon.
- You can still search via the CLI (`deepfinder "query"`).
- You can still search via the REPL (just run `deepfinder`).
- Only the global keyboard shortcut is unavailable.

### Why Accessibility Is Needed

macOS requires Accessibility permission for any app that wants to register a global keyboard shortcut (via `RegisterEventHotKey` or `CGEventTap`). This is a system-level security policy -- the same permission Alfred and Raycast require for their hotkeys.

### Grant Accessibility Permission

1. Open **System Settings** > **Privacy & Security**.
2. Select **Accessibility** from the list.
3. Toggle **DeepFinder** ON.
4. If DeepFinder is not listed, click **+**, navigate to `/Applications/DeepFinder.app`, and add it.

> **Screenshot 3**: System Settings > Privacy & Security > Accessibility pane, with DeepFinder toggled ON. Annotate with a note: "Only needed for global hotkey -- search works without this."

### Test the Hotkey

After granting Accessibility, press **Control-Command-K** from any application. The search panel should appear at the top center of your screen.

If the hotkey does not work, another app may have claimed it. VS Code, Obsidian, and several other tools use Control-Command-K by default. Change the hotkey in DeepFinder's settings panel (accessible from the menu bar icon).

### Hotkey Conflict Detection

DeepFinder automatically detects hotkey conflicts at startup. If another app has registered Control-Command-K:

1. A notification appears: "Hotkey Control-Command-K is in use by [App Name]. Would you like to choose a different hotkey?"
2. Click **Choose Hotkey** to open the settings panel.
3. Pick an alternative, such as Control-Command-Space.

> **Design note**: This step intentionally comes AFTER Full Disk Access and Index Scope. The hotkey is a convenience feature. The index is the product. We never ask for convenience permissions before core functionality permissions.

---

## Step 4: AI Setup -- Opt-In Privacy-First Intelligence

### This Is Optional

AI features are **completely optional**. DeepFinder's core search works without any AI configuration. No AI features are active until you explicitly enable them and provide an API key.

### What AI Can Do

| Feature | Cloud or Local | What It Does |
|---------|---------------|--------------|
| Natural language search | Cloud (API key required) | Type "large PDF reports from last month" instead of `ext:pdf size:>10mb dm:lastmonth` |
| Vision tagging | Local (Apple Neural Engine) | Automatically tags images with content labels (sunset, beach, document, etc.) |
| Speech input | Local (Apple Speech) | Speak your search query instead of typing |
| Clipboard search | Local | Search text you recently copied |
| Match explanation | Local | Shows why a file matched your query |
| Semantic grouping | Cloud (API key required) | Groups results by concept, not just filename |

### What AI Never Does

- **Never reads file contents without your explicit action.** File contents are only accessed during on-demand content search.
- **Never uploads files to the cloud.** Only search query text and file metadata (names, extensions, capped at 20 items) are sent to cloud AI providers.
- **Never auto-enables.** You must explicitly configure an API key.

Full details: [AI Search Guide](ai-search.md) and [Privacy Model](../explanation/privacy-model.md).

### Enable AI Features

```bash
# 1. Enable AI
deepfinder config set ai.enabled true

# 2. Choose a provider
deepfinder config set ai.model deepseek     # or: qwen

# 3. Set your API key (stored encrypted at ~/.deep-finder/secrets.json, permissions 600)
deepfinder config set ai.apiKey "sk-..."
```

Supported cloud providers:

| Provider | Model | Pricing |
|----------|-------|---------|
| DeepSeek | `deepseek-chat` | ~$0.14 / 1M input tokens |
| Qwen (Tongyi Qianwen) | `qwen3.6-plus` | ~$0.50 / 1M input tokens |

### Verify Privacy Before Using Cloud AI

The `:data_preview` command shows exactly what data would be sent to your AI provider:

```
> :data_preview
=== AI Data Preview ===
Provider: deepseek
Model: deepseek-chat
System prompt: You are a search assistant...
Context: query="report", resultCount=42
File metadata (capped at 20):
  report_q1.pdf (154 KB)
  report_q2.pdf (201 KB)
  ...
```

No file contents. No full paths. No personal data. Use this before any cloud AI search.

> **Screenshot 4**: The AI setup panel showing the provider selector (DeepSeek / Qwen), API key field (masked), and the local features that work without any key (vision tagging, speech, clipboard, match explainer). Include the `:data_preview` output as a transparency callout.

---

## Step 5: First Search -- Your Aha Moment

### The Goal

You should see your first search result in under 100 milliseconds. If the daemon has finished building its index, it is literally that fast.

### Guided First Search

#### If You Use the CLI

```bash
# 1. Check daemon is live and index is ready
deepfinder daemon status

# 2. Search for something you know exists on your Mac
deepfinder "README"

# 3. Try a more specific query
deepfinder "ext:pdf report"

# 4. See what the index covers
deepfinder :stats
```

#### If You Use the GUI

1. Press **Control-Command-K** (or click the menu bar icon).
2. Type the name of a file you know exists.
3. Results appear as you type, character by character.
4. Use **Up/Down arrows** to navigate results, **Space** to preview, **Enter** to open.

### What You Should See

- **Filename**: Matching characters are bolded.
- **Path**: Parent directory shown, truncated for long paths.
- **Match badge**: Shows how the match was found (exact, prefix, substring, pinyin).
- **File metadata**: Size, modification date.

### Celebrating the Aha Moment

If results appear instantly -- that is the moment. You just searched your entire Mac faster than you can blink. That speed does not degrade as your file count grows. 10,000 files or 10,000,000 files -- same sub-100ms response.

### What If No Results Appear?

Do not panic. DeepFinder's diagnostic system tells you **why** results are missing -- unlike Spotlight, which stays silent.

Possible causes shown in the results area:

| Message | What It Means | Fix |
|---------|--------------|-----|
| "Full Disk Access not enabled" | FDA permission missing or revoked | Go to [Step 1](#step-1-full-disk-access----this-must-come-first) |
| "Index is rebuilding" | Index was reset or is catching up after many file changes | Wait for state to reach `live` (~10-30 seconds) |
| "File may be in an excluded directory" | The file lives in a path you excluded | Check `deepfinder config get excludedPaths` |
| "Index is stale" | Daemon restarted but index not yet verified | Allow verification to complete (~30 seconds) |

This transparency is DeepFinder's competitive advantage: **we tell you why a search failed, so you can fix it.**

> **Screenshot 5a**: The CLI terminal showing `deepfinder daemon status` with all-green output, followed by a successful search with results.
>
> **Screenshot 5b**: The GUI search panel showing a query in the search field, results displayed with match badges, and the Intelligence Glow active along the top edge.
>
> **Screenshot 5c**: The diagnostic message display when a search returns no results, showing the specific cause and a "Fix This" button that links to the relevant settings.

---

## Permission Diagnostics

### The "Re-check Permissions" Button

DeepFinder includes a permission diagnostic tool accessible from both CLI and GUI:

**CLI**:
```bash
deepfinder daemon diagnose
```

**GUI**: Settings panel > Permissions tab > "Check Permissions" button.

### Permission Status Display

The diagnostic shows the status of each required permission:

```
=== DeepFinder Permission Diagnostic ===

Full Disk Access ............. ✅ Granted
  → Coverage: 98.2% (1,234,567 of ~1,257,000 files reachable)
  → Protected directories accessible: ~/Documents, ~/Desktop, ~/Downloads, ~/Photos

Accessibility ................ ✅ Granted
  → Hotkey: Control-Command-K registered successfully
  → No conflicts detected

Speech Recognition ........... ⚠️ Not Requested
  → Speech input not yet used. Permission will be requested on first use.

Microphone ................... ⚠️ Not Requested
  → Microphone not yet used. Permission will be requested on first use.

AI Provider (deepseek) ....... ✅ Configured
  → API key: Present (stored in Keychain)
  → Last connection: 2026-06-03 09:15:32 (success)

Apple Neural Engine .......... ✅ Available
  → Vision tagging: Active (23,456 images tagged)
```

### Status Icons

| Icon | Meaning |
|------|---------|
| ✅ Granted | Permission is active and working |
| ⚠️ Partial | Permission granted but with limitations (e.g., FDA granted but some directories still unreachable) |
| ❌ Denied | Permission was explicitly denied by the user |
| ⬚ Not Requested | Permission has not been prompted yet |
| 🔄 Expired | Permission was granted but has been reset (common after macOS updates) |

### What to Do If Denied

If you denied a permission during the initial prompt, macOS does not show the prompt again. You must manually enable it:

#### Full Disk Access

1. **System Settings** > **Privacy & Security** > **Full Disk Access**.
2. Find `deepfinder-daemon` in the list.
3. If it is OFF, toggle it ON.
4. If it is not listed, click **+**, navigate to `/opt/homebrew/bin/`, select `deepfinder-daemon`, and click **Open**.
5. If it IS listed and ON but the diagnostic still shows ❌ Denied: toggle it OFF, wait 5 seconds, toggle it ON. This forces macOS to re-evaluate the TCC database entry.

#### Accessibility

1. **System Settings** > **Privacy & Security** > **Accessibility**.
2. Find **DeepFinder** in the list.
3. Toggle ON.
4. If not listed, click **+**, navigate to `/Applications/DeepFinder.app`, and add it.

#### Speech Recognition

Speech Recognition permission is requested on first use. If denied:
1. **System Settings** > **Privacy & Security** > **Speech Recognition**.
2. Toggle **DeepFinder** ON.

#### Microphone

Microphone permission is requested on first use. If denied:
1. **System Settings** > **Privacy & Security** > **Microphone**.
2. Toggle **DeepFinder** ON.

> **Screenshot PD-1**: The permission diagnostic panel showing all permissions with their status icons. Highlight the "Re-check" button and the "Fix This" link next to any ❌ or ⚠️ status.
>
> **Screenshot PD-2**: The System Settings path for each permission type, shown as a step-by-step visual guide with annotated screenshots.

---

## Trust Building: What's Indexed and What's Not

### Index Statistics

DeepFinder shows you exactly what it knows about your files:

```bash
deepfinder :stats
```

```
=== Index Statistics ===
State:                live
Files indexed:        1,234,567
Directories watched:  45,678
Total index size:     847 MB (RAM)
Coverage estimate:    98.2%

Index structures:
  Trie nodes:         3,456,789
  FullSubstringMap:   1,234,567 entries
  TrigramIndex:       12,345 entries (for paths > 64 chars)
  PinyinIndex:        23,456 entries

By volume:
  Macintosh HD:        1,180,000 files
  External SSD:        54,567 files

Last full scan:       2026-06-03 09:15:32 (completed in 18.3s)
Last FSEvents event:  2026-06-03 10:42:15 (3s ago)
```

### Where Are My Files?

To see exactly which directories DeepFinder is watching:

```bash
deepfinder daemon status --verbose
```

```
=== Watched Directories ===
✅ /Users/nadav/                        (1,180,000 files)
✅ /Volumes/External SSD/               (54,567 files)
❌ /System/                             (excluded: system volume)
❌ /Users/nadav/.Trash/                 (excluded: trash)
❌ /Users/nadav/Library/Caches/         (excluded: user config)
❌ /Users/nadav/Projects/*/node_modules/ (excluded: .deepfinderignore pattern)
```

### What's NOT Being Indexed? -- Explicit Exclusion List

Transparency about what is excluded is as important as what is included:

```bash
deepfinder config get excludedPaths
```

```
=== Exclusion Rules ===
1. /System/                     [default]  System volume
2. ~/.Trash/                    [default]  Trash
3. ~/.deep-finder/              [default]  DeepFinder data
4. **/node_modules/             [default]  Node.js dependencies
5. **/.git/                     [default]  Git repository data
6. ~/Library/Caches/            [user]     App caches
7. ~/VirtualMachines/           [user]     VM images
8. ~/Projects/*/build/          [.deepfinderignore]  Build output
```

Each exclusion shows its origin (`[default]`, `[user]`, or `[.deepfinderignore]`) so you know exactly why a path is excluded and how to change it.

### The "Search This Folder" Test

To verify a specific directory is being indexed:

```bash
# Create a unique test file
touch ~/Documents/__deepfinder_test__

# Search for it
deepfinder "__deepfinder_test__"

# Clean up
rm ~/Documents/__deepfinder_test__
```

If the test file does not appear in results, Full Disk Access is not covering that directory. Run the [permission diagnostic](#permission-diagnostics) to identify why.

> **Screenshot TB-1**: The index statistics output showing file counts, coverage percentage, and structure sizes.
>
> **Screenshot TB-2**: The exclusion list with origin annotations, showing the difference between default, user-configured, and .deepfinderignore exclusions.

---

## Error Recovery

### Daemon Not Running

**Symptom**: CLI shows "Connection refused" or "Daemon not running."

**Auto-recovery**: The CLI automatically starts the daemon on the first query if it is not running.

**Manual recovery**:
```bash
# Start the daemon
deepfinder daemon start

# If that fails, check for stale socket
rm ~/.deep-finder/session/ipc.sock
deepfinder daemon start
```

Full daemon troubleshooting: [Daemon Management](daemon-manage.md).

### Index Stale or Corrupt

**Symptom**: `deepfinder daemon status` shows `stale` indefinitely, or file count is suspiciously low.

**Recovery**:
```bash
# Full index rebuild
deepfinder daemon stop
rm ~/.deep-finder/cache/index.db
deepfinder daemon start
# Wait 10-30 seconds for the index to rebuild
deepfinder daemon status
# Should show: State: live
```

Full troubleshooting: [Troubleshooting](troubleshooting.md).

### Permissions Lost After macOS Update

**This is a known macOS behavior.** Major version upgrades (e.g., macOS 26 to 27) can silently reset the TCC (Transparency, Consent, and Control) database, which stores your permission grants.

**Symptom**: After a macOS update, searches return fewer results than before, or the hotkey stops working.

**Recovery**:

1. Run the permission diagnostic:
   ```bash
   deepfinder daemon diagnose
   ```

2. If Full Disk Access shows ❌ or 🔄:
   - Open **System Settings** > **Privacy & Security** > **Full Disk Access**.
   - Find `deepfinder-daemon`. If it is ON, toggle it OFF, wait 5 seconds, toggle it ON.
   - If it is missing, add it again via the **+** button.

3. If Accessibility shows ❌ or 🔄:
   - Open **System Settings** > **Privacy & Security** > **Accessibility**.
   - Toggle DeepFinder OFF, wait 5 seconds, toggle ON.

4. Rebuild the index to ensure completeness:
   ```bash
   deepfinder daemon stop
   rm ~/.deep-finder/cache/index.db
   deepfinder daemon start
   ```

**Prevention**: DeepFinder checks permissions at every startup and displays a warning in search results if any are missing. This warning appears as a non-intrusive banner -- not a modal dialog -- so it does not block you from searching. See [UX-M06: Index Health Indicator](../superpowers/specs/ux/2026-06-03-user-experience-requirements.md) for the design specification.

### Daemon Crash Recovery

**Symptom**: Queries fail mid-session with "Connection lost" or "Broken pipe."

The CLI automatically reconnects on the next query. If it does not:

```bash
deepfinder daemon restart
```

Check the logs for crash cause:

```bash
tail -100 ~/.deep-finder/logs/daemon-stderr.log
```

---

## Onboarding Checklist

Use this checklist to track your setup progress. Check off each item as you complete it.

### Core Setup (Required)

- [ ] **Full Disk Access granted** -- System Settings > Privacy & Security > Full Disk Access > deepfinder-daemon ON
- [ ] **Daemon running** -- `deepfinder daemon status` shows `State: live`
- [ ] **Index is complete** -- Coverage > 90%, file count roughly matches expectation
- [ ] **First search succeeded** -- Searched for a known file and saw instant results
- [ ] **Exclusions reviewed** -- Checked `deepfinder config get excludedPaths`, added directories you do not need indexed

### Convenience Setup (Recommended)

- [ ] **Accessibility granted** -- System Settings > Privacy & Security > Accessibility > DeepFinder ON
- [ ] **Hotkey tested** -- Control-Command-K opens the search panel from any app
- [ ] **Hotkey conflict resolved** -- No other app claims Control-Command-K, or changed to an alternative hotkey

### Advanced Setup (Optional)

- [ ] **AI provider configured** -- `deepfinder config set ai.enabled true` + API key set
- [ ] **Natural language search tested** -- Tried a plain-English query like "large PDFs from last week"
- [ ] **Privacy verified** -- Ran `:data_preview` to see exactly what cloud AI receives
- [ ] **Speech input tested** -- Granted Speech Recognition + Microphone, used the microphone button in the GUI
- [ ] **LaunchAgent installed** -- `deepfinder daemon install` to auto-start daemon on login

### Documentation Reference

| You need help with... | Read this |
|----------------------|-----------|
| Installation issues | [Installation Guide](../INSTALL.md) |
| Search syntax | [Find Files](find-files.md) |
| Advanced search | [Exact Search](exact-search.md) |
| Result filtering | [Filter Results](filter-results.md) |
| AI features | [AI Search](ai-search.md) |
| Daemon management | [Daemon Management](daemon-manage.md) |
| Configuration | [Configure](configure.md) |
| Troubleshooting | [Troubleshooting](troubleshooting.md) |
| Privacy model | [Privacy Model](../explanation/privacy-model.md) |
| How it works | [Architecture](../explanation/architecture.md) |

---

## Screenshot Specifications

This section lists every screenshot needed for this guide. Screenshots should be taken on macOS 26 (Tahoe) in Light mode at 2x resolution (Retina).

### Step 0: Welcome

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-00` | Welcome window with product icon, name, value propositions, and "Get Started" button | 520 x 520 | The current OnboardingView window. Capture before any interaction. |

### Step 1: Full Disk Access

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-01a` | System Settings > Privacy & Security > Full Disk Access pane | Full window | `deepfinder-daemon` toggled ON. Red arrow annotation pointing to the toggle. |
| `onboarding-01b` | File browser dialog with `deepfinder-daemon` selected | Dialog only | Cmd+Shift+G path entry visible: `/opt/homebrew/bin/`. |
| `onboarding-01c` | Terminal output of `deepfinder daemon status` showing live state and high file count | Terminal window | Green checkmarks, healthy stats. |

### Step 2: Index Scope

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-02a` | Terminal output of `deepfinder daemon status --verbose` showing watched directories | Terminal window | Show both ✅ and ❌ entries with reasons. |
| `onboarding-02b` | Terminal output of `deepfinder config get excludedPaths` with origin annotations | Terminal window | Show [default], [user], and [.deepfinderignore] origins. |

### Step 3: Accessibility

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-03a` | System Settings > Privacy & Security > Accessibility pane | Full window | DeepFinder toggled ON. Annotation: "Only needed for global hotkey." |
| `onboarding-03b` | The search panel appearing after pressing Control-Command-K | Full desktop | Panel at top center, search field focused. Show the Intelligence Glow animation if possible (static frame with glow visible). |

### Step 4: AI Setup

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-04a` | AI settings panel showing provider selector, API key field (masked), and local features list | Settings window | Include the "no key needed" callout for local features. |
| `onboarding-04b` | Terminal output of `:data_preview` showing what cloud AI receives | Terminal window | Show the capped metadata, no file contents. |

### Step 5: First Search

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-05a` | CLI: Terminal showing `deepfinder daemon status` output followed by a successful search | Terminal window | All-green status, instant results. |
| `onboarding-05b` | GUI: Search panel with query entered, results displayed, match badges visible | Panel only | Show a few results with varying match types. |
| `onboarding-05c` | GUI: Diagnostic message when search returns no results | Panel only | Show the "No results" message with cause and "Fix This" button. |

### Permission Diagnostics

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-pd-01` | Permission diagnostic panel showing all permissions with status icons | Settings panel | Include at least one ✅, one ⚠️, and one ❌ for variety. |
| `onboarding-pd-02a` | System Settings navigation path for Full Disk Access | Series of 3 small screenshots | Step-by-step: Sidebar > Full Disk Access > Toggle. |
| `onboarding-pd-02b` | System Settings navigation path for Accessibility | Series of 2 small screenshots | Sidebar > Accessibility > Toggle. |

### Trust Building

| ID | Description | Dimensions | Notes |
|----|-------------|------------|-------|
| `onboarding-tb-01` | Terminal output of `deepfinder :stats` showing full index statistics | Terminal window | Show all stats: file count, structures, volumes, timestamps. |
| `onboarding-tb-02` | Exclusion list with origin annotations | Terminal window | Clearly distinguish default vs user vs .deepfinderignore origins. |

### Total Screenshots Needed: 17

Priority order for initial release:
1. `onboarding-01a`, `onboarding-01b` -- Full Disk Access steps (critical for user success)
2. `onboarding-03a` -- Accessibility setup
3. `onboarding-05b` -- GUI search panel (the "aha moment")
4. `onboarding-pd-01` -- Permission diagnostic
5. All others can ship in subsequent releases

---

## Appendix: The FDA-First Redesign Rationale

### The Problem (Current Onboarding, v3.0)

The current onboarding flow (as implemented in `OnboardingView.swift`) has a critical ordering flaw:

1. Welcome screen with feature cards
2. "Set Up Permissions" button → opens **Accessibility** settings only
3. "Get Started" button → completes onboarding

**Full Disk Access is never mentioned in onboarding.** Users can complete onboarding without knowing FDA exists. They then search for files in `~/Documents` and get no results -- and since no warning is shown (the index appears "live" because it indexed what it could reach), they conclude DeepFinder is broken.

### The Solution (This Guide, v3.2 Target)

1. **FDA first**: Before any other permission, before any feature card, we explain exactly what you lose without FDA.
2. **Transparency**: Show what's indexed, what's excluded, and why -- at all times.
3. **Permission ordering by impact**: Core functionality (FDA) → convenience (Accessibility) → enhancement (AI). Never reverse.
4. **Trust through explicitness**: Every exclusion has a reason. Every permission explains what it enables. Every search failure shows a cause.

### What Needs to Change in Code

This document is the UX specification. The corresponding code changes for `OnboardingView.swift`:

1. Replace the single "Set Up Permissions" button with a multi-step flow (PageTabView or NavigationStack).
2. Add a Full Disk Access step with explanatory text and an "Open System Settings" button that navigates to the FDA pane.
3. Add an `openFullDiskAccessSettings()` method (analogous to the existing `openAccessibilitySettings()`).
4. Add an index scope step showing default exclusions with toggles.
5. Move Accessibility setup to a separate, clearly-labeled-optional step after FDA.
6. Add an AI opt-in step.
7. Add a "First Search" guided step.
8. Add permission status check at startup that warns if FDA is missing (currently only Accessibility is checked).

See [USER_JOURNEY.md §3.3](../superpowers/USER_JOURNEY.md#33-首次运行) for the user journey specification and [UX Requirements REQ-UX-C04](../superpowers/specs/ux/2026-06-03-user-experience-requirements.md) for the FDA trust crisis requirement.
