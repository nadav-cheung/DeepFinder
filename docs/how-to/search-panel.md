# Search Panel

## You want to use the GUI search panel

DeepFinder includes a native macOS search panel you can summon from anywhere with a keystroke. Results appear as you type, no waiting.

**Prerequisites**: DeepFinder installed and daemon running. If you have not done a first search yet, start with [60-Second Quick Start](../tutorial/first-search.md).

---

## Step 1: Open the Panel

Press **Control+Command+K** (Ctrl+Cmd+K) from anywhere.

The first time you use the hotkey, macOS prompts you to grant **Accessibility** permission. This is required so the system can deliver the global keystroke to DeepFinder. Open System Settings, navigate to **Privacy and Security > Accessibility**, and toggle DeepFinder ON.

If the hotkey conflicts with another app, DeepFinder retries registration automatically. You can also open the panel by clicking the DeepFinder icon in the menu bar (magnifying glass, no Dock icon).

---

## Step 2: Understand the Panel

The search panel is a floating window that stays above other apps. Two visual details:

- **Liquid Glass**: The panel background uses the macOS Liquid Glass effect (`.glassEffect()`), blending subtly with whatever is behind it.
- **Intelligence Glow**: A rotating angular gradient in teal, violet, coral, and amber animates at 60fps along the top edge while the panel is active. It is cosmetic only -- no AI processing happens unless you enable AI features.

---

## Step 3: Search

Type your query. Results appear immediately -- the daemon holds the entire index in RAM, so there is no debounce and no network delay. The search syntax is the same as the CLI: keywords, wildcards, boolean operators, modifiers. See [Find Files](find-files.md) for the full syntax reference.

---

## Step 4: Read a Result Row

Each result row shows:

| Element | What it tells you |
|---------|-------------------|
| **File icon** (16x16) | File type, cached by extension |
| **Filename** | With matching characters **bolded** for the query |
| **Path** | Parent directory, truncated with `...` for long paths |
| **Match badge** | `exa` = exact, `pre` = prefix, `sub` = substring, `pin` = pinyin |
| **Size** | Human-readable: KB, MB, GB, TB |
| **Date** | Modification date |

---

## Step 5: Act on a Result

| You want to... | Do this |
|----------------|---------|
| Open the file | **Double-click** the row, or select it and press **Enter** |
| See it in Finder | Select the row and press **Cmd+Enter** |
| Quick Look preview | Select the row and press **Space** (arrow keys navigate between previews) |
| Copy the path | **Right-click** the row and choose **Copy Path** |
| See file info | **Right-click** the row and choose **Get Info** |
| Drag to another app | **Drag** the row and drop it on Finder, Terminal, or any app that accepts file URLs |

---

## Where to Go Next

| You want to... | Read this |
|---------------|-----------|
| Learn all search syntax | [Find Files](find-files.md) |
| Filter by size, date, type | [Filter Results](filter-results.md) |
| Use the REPL instead | [REPL Interaction](repl-interact.md) |
| Change the hotkey or settings | [Configure](configure.md) |
| Enable AI natural language search | [AI Search](ai-search.md) |
| Understand how it works | [Architecture](../explanation/architecture.md) |
| Have a problem? | [Troubleshooting](troubleshooting.md) |
