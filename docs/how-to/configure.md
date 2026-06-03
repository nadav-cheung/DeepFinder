# Configure DeepFinder

## You want to customize DeepFinder

DeepFinder works out of the box with sensible defaults, but you can tune it to
fit your workflow -- exclude noisy directories, raise the result limit, or
reset everything and start over. All configuration lives in one file:
`~/.deep-finder/settings.json` (permissions 600, owner-only).

---

## Change a single setting

Use `config set` with a key and value. The daemon picks up the change
immediately -- no restart needed.

```bash
deepfinder config set maxResults 500
deepfinder config set indexBatchSize 200
```

**Supported types**: strings, integers, booleans, and JSON arrays (for list keys).

---

## Check what a setting is right now

Use `config get` to inspect one key:

```bash
deepfinder config get maxResults
# → 500
```

Use `config list` to see every key and its current value at once:

```bash
deepfinder config list
```

---

## Exclude paths from indexing

The `excludedPaths` key is an array of directory paths. DeepFinder skips these
entirely -- their files never enter the index.

**Default**: `["/System", "/Library"]` -- system directories are excluded by
default because you rarely search them, and skipping them keeps the index lean.

The value is a JSON array, so quote it:

```bash
# Add a directory to the exclusion list (replace the whole array)
deepfinder config set excludedPaths '["/System","/Library","/Users/nadav/Downloads"]'
```

**Common exclusion targets**:

| You want to exclude... | Add this path |
|------------------------|---------------|
| Node.js project cruft | `/Users/you/Projects` (see walkthrough below for finer control) |
| Time Machine backups | Use `excludedVolumes` instead (see below) |
| Build output directories | `/Users/you/Projects/myapp/build` |
| Virtual machine images | `/Users/you/VMs` |

> Note: `config set` replaces the entire array. To append, get the current
> value first, add your entry, then set the new array.

---

## Exclude an entire volume

For external drives you never want indexed (Time Machine disks, archival
storage), use `excludedVolumes`:

```bash
deepfinder config set excludedVolumes '["/Volumes/Time Machine"]'
```

Excluded volumes are skipped during scanning. When a volume is unmounted,
its files are automatically removed from the index. Excluding it up-front
avoids ever indexing it in the first place.

---

## Walkthrough: Exclude `node_modules` from your projects

You work in `/Users/nadav/Projects` and `node_modules` directories add
hundreds of thousands of tiny files to the index -- files you never search.
You want them gone.

### Step 1: Check current exclusions

```bash
deepfinder config get excludedPaths
# → ["/System","/Library"]
```

### Step 2: Add your projects directory

```bash
deepfinder config set excludedPaths '["/System","/Library","/Users/nadav/Projects"]'
```

The daemon removes matching files from the index on the next scan cycle.
Query latency improves because there are fewer irrelevant results.

### Step 3: Verify

```bash
deepfinder config get excludedPaths
# → ["/System","/Library","/Users/nadav/Projects"]
```

Run a search that used to return `node_modules` noise -- those results are gone.

### Finer control

Excluding all of `~/Projects` is coarse. If you want only `node_modules`
directories gone, create a `.deepfinderignore` file in your project root:

```
node_modules/
```

DeepFinder respects `.deepfinderignore` files the same way git respects
`.gitignore`. This gives you per-project control without touching `config set`.

---

## Raise or lower the result cap

The default `maxResults` is 1000 -- enough for most interactive use. Adjust
it when you need more (for scripting) or fewer (for faster terminal output):

```bash
# Return up to 5000 results -- useful for batch scripts
deepfinder config set maxResults 5000

# Return at most 100 results -- tighter, faster terminal output
deepfinder config set maxResults 100
```

The `--limit` CLI flag overrides this per-query: `deepfinder --limit 50 "query"`.

---

## Tune SQLite write batching

`indexBatchSize` controls how many file records are written per SQLite
transaction. The default (100) balances throughput and crash safety. Adjust
it if you observe write stalls on very large file systems:

```bash
# Larger batches = faster bulk indexing, but more lost on crash
deepfinder config set indexBatchSize 500
```

In most cases the default is fine. Only tune this if you are indexing over a
million files and want to speed up the initial build.

---

## Reset everything to factory defaults

If configuration drifts and you want a clean slate:

```bash
deepfinder config reset
```

This prompts for confirmation (`y/N`), then writes the defaults back to
`settings.json`. The daemon picks up the new values immediately.

---

## Configuration file reference

| Setting | Type | Default | What it does |
|---------|------|---------|--------------|
| `excludedPaths` | `[String]` | `["/System", "/Library"]` | Directory paths skipped during indexing |
| `excludedVolumes` | `[String]` | `[]` | Volume mount paths skipped (e.g. Time Machine) |
| `indexBatchSize` | `Int` | `100` | Records per SQLite batch write |
| `maxResults` | `Int` | `1000` | Maximum results returned per query |
| `configVersion` | `Int` | `1` | Schema version (for future migrations) |

All keys are also settable from the REPL with `:config KEY [VALUE]`.

---

## Where to go next

| You want to... | Read this |
|---------------|-----------|
| See every config key in detail | [Configuration Reference](../reference/config-keys.md) |
| Understand the search syntax | [Search Syntax Reference](../reference/search-syntax.md) |
| Find files by type, date, or size | [Filter Results](filter-results.md) |
| Learn all search tricks | [Find Files](find-files.md) |
| Set up the daemon on login | [Install Daemon](install-daemon.md) |
| Debug a problem | [Troubleshooting](troubleshooting.md) |
