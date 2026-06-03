## You want to open or preview a file you found

DeepFinder lets you open, preview, or reveal files from the search results using keyboard shortcuts in the GUI or commands in the CLI REPL.

### Open a file with its default application

Press **Enter** or double-click a result row. The file opens in whichever application macOS associates with its type -- PDF in Preview, images in Preview, text files in your default editor.

In the REPL, use `:open N` where N is the result number shown in the list.

### Reveal a file in Finder

Press **Cmd+Enter** (Command+Enter). Finder opens a new window with the file selected, so you can see surrounding files, drag it elsewhere, or use Finder's Get Info.

In the REPL, use `:reveal N`.

### Quick Look a file without opening it

Press **Space** on a selected result. A QLPreviewPanel slides up showing the file contents in-place -- images render at full resolution, documents scroll, and you can browse other results with Up/Down before dismissing with Space again.

### Right-click for more actions

Right-click any result row to open a context menu with four options: **Open** (default app), **Reveal in Finder**, **Copy Path** (copies the full POSIX path to the clipboard), and **Get Info** (Finder's standard Get Info panel for permissions, size, and metadata).

### Drag a file to Finder or Terminal

Drag a result row directly out of the search panel. Drop it onto a Finder window to copy or move the file, onto a Terminal window to paste its full path, or onto any app that accepts file URL drops.

---

**Next steps:**

- [Find Files](find-files.md) — refine your queries to find files faster
- [REPL Interaction](repl-interact.md) — learn all REPL commands including `:explain` and `:undo`
- [Search Panel](search-panel.md) — full GUI documentation including the global hotkey and settings
