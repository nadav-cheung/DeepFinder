# Use the Interactive REPL

## You want to use the interactive REPL

The REPL (Read-Eval-Print Loop) is DeepFinder's interactive terminal mode. You type queries, get instant results, and use commands to open files, explain matches, and undo operations -- all without leaving your terminal.

### Start the REPL

Run `deepfinder` without any arguments:

```bash
deepfinder
> _
```

The `>` prompt means the REPL is ready. The daemon starts automatically if it is not already running. Type a query and press Enter to search.

### Commands

Type a query directly, or prefix commands with `:`.

| Command | Alias | Description |
|---------|-------|-------------|
| `:help` | `:h` | Show all available commands |
| `:quit` | `:q` | Exit the REPL (Ctrl+D also works) |
| `:stats` | | Show index statistics: file count, index state, memory usage |
| `:daemon` | | Show daemon status: PID, uptime, index state, connections |
| `:open N` | | Open result N with the default application (1-based index) |
| `:reveal N` | | Reveal result N in Finder |
| `:explain N` | | Show why result N matched (match type, position, reasoning) |
| `:config KEY [VALUE]` | | Get or set a configuration key |
| `:data_preview` | `:dataPreview` | Show what data would be sent to AI providers (privacy transparency) |
| `:undo` | | Undo the last file operation (move/copy/rename) |

### Example Workflow

Here is a typical REPL session showing search, open, explain, and metadata filtering:

```
> vacation photo
1. /Users/nadav/Pictures/2026/vacation_beach.jpg    2.4 MB   exa  2026-03-15
2. /Users/nadav/Pictures/2026/vacation_hotel.jpg    1.8 MB   exa  2026-03-16
3. /Users/nadav/Documents/vacation_plan.md           12 KB    sub  2026-02-28
3 results

> :open 1
# Opens vacation_beach.jpg in Preview

> :explain 3
Match type: substring
Position: 0
Reason: Substring match: filename contains 'vacation'

> ext:jpg dm:thisweek
1. /Users/nadav/Documents/screenshot_20260531.jpg    856 KB   exa  2026-05-31
1 result
```

Each result line shows the file path, size, match badge (**exa**=exact, **pre**=prefix, **sub**=substring, **pin**=pinyin), and modification date.

### History

The REPL saves command history to `~/.deep-finder/history`. Up to 1000 entries are retained. Consecutive duplicates are suppressed.

- Press **Up** to recall the previous command.
- Press **Down** to move forward through history.
- History persists across sessions -- restarting the REPL restores your previous queries and commands.

### Exit the REPL

Use `:quit`, `:q`, or press **Ctrl+D** to exit. The daemon keeps running in the background so your next query is instant.

---

**Where to Go Next**

| You want to... | Read this |
|---------------|-----------|
| Learn all search syntax (wildcards, boolean, regex) | [Find Files](find-files.md) |
| Filter results by size, date, or media metadata | [Filter Results](filter-results.md) |
| Understand what `:explain` shows in detail | [Exact Search](exact-search.md) |
| Use AI to translate plain English into search queries | [AI Search](ai-search.md) |
| Get a one-page syntax cheat sheet | [Search Syntax Reference](../reference/search-syntax.md) |
| Understand how the daemon + REPL architecture works | [Architecture](../explanation/architecture.md) |
