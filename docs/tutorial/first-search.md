# ~2 Minute Quick Start

Get DeepFinder running and find your first file — in about two minutes.

**Prerequisites**: macOS 26 (Tahoe), Apple Silicon (M4+), internet connection for install.

---

## Step 1: Install (10 seconds)

```bash
brew install nadav/deepfinder/deepfinder
```

Expected output:
```
==> Installing deepfinder from nadav/deepfinder
🍺  /opt/homebrew/bin/deepfinder
```

If you don't use Homebrew, [download the DMG](https://github.com/nadav/deepfinder/releases) and drag DeepFinder to Applications.

> **Distribution**: DeepFinder requires Full Disk Access and cannot be sandboxed, so it is not available on the Mac App Store. It is distributed via Homebrew and GitHub Releases (DMG). Both are signed and notarized.

---

## Step 2: Grant Full Disk Access (30 seconds)

DeepFinder needs permission to search your files. This is required once.

1. When prompted, click **Open System Settings**
2. Navigate to **Privacy & Security → Full Disk Access**
3. Toggle **DeepFinder** ON
4. If DeepFinder isn't listed, click **+** and add it from `/opt/homebrew/bin/` or `/Applications/`

> 💡 **Why this matters**: Without Full Disk Access, DeepFinder can't search `~/Documents`, `~/Desktop`, and `~/Downloads`. You'll miss files without knowing it.

---

## Step 3: Your First Search (5 seconds)

```bash
deepfinder "readme"
```

The daemon starts automatically. On first run, it builds the index — you'll see a progress indicator:

```
Indexing...  ████████░░░░░░░░  142,391 files
```

You can start searching immediately — results appear as the index builds.

---

## Step 4: Open Your File (15 seconds)

Start the interactive REPL by running `deepfinder` with no arguments, then type your query:

```
$ deepfinder
> readme
1. /Users/nadav/Projects/deepfinder/README.md     12 KB   exa  2026-05-20
2. /Users/nadav/Projects/website/readme.html        8 KB   sub  2026-03-10
3. /Users/nadav/Documents/readme_template.txt        2 KB   sub  2025-11-01
42 results

> :open 1
# Opens README.md in your default editor
```

Or use the GUI: press **⌃⌘K** to open the search panel, type your query, and press **Enter** on any result.

---

## 🎉 You're Done

You just installed DeepFinder, granted permissions, ran your first search, and opened a file.

---

## Where to Go Next

| You want to... | Read this |
|---------------|-----------|
| Find files by type, date, or size | [Filter Results](../how-to/filter-results.md) |
| Learn all the search tricks | [Find Files](../how-to/find-files.md) |
| Use the GUI search panel | [Search Panel](../how-to/search-panel.md) |
| Understand how DeepFinder works | [Architecture](../explanation/architecture.md) |
| Compare with Spotlight/Alfred/etc. | [Comparison](../COMPARISON.md) |
| Have a problem? | [FAQ](../how-to/faq.md) or [Troubleshooting](../how-to/troubleshooting.md) |

---

> ⚡ **Pro tip**: Run `deepfinder install` to start the daemon automatically on login. Then `⌃⌘K` to search from anywhere, anytime.
