# Roadmap

This roadmap follows a **Now / Next / Later** structure — the current shipped state,
the next planned work, and the longer-term direction. It is the forward-looking
companion to the detailed requirement specs in
[`docs/superpowers/specs/reqs/`](docs/superpowers/specs/reqs/) (151 of 158 REQs done).

| Status | Meaning |
|--------|---------|
| ✅ Shipped | Released and tagged |
| 🔨 Active | Currently in development |
| 📋 Planned | Scoped, not started |
| 💡 Exploring | Under consideration, not yet a REQ |

> DeepFinder is a maintained side project. Dates are targets, not commitments.
> The best way to influence this roadmap is to [open an issue](https://github.com/nadav-cheung/DeepFinder/issues).

---

## Now ✅ — v3.2.0 (current release)

The full local file-search stack is shipped and production-shaped:

- **Search engine** — Trie + FullSubstringMap + TrigramIndex + PinyinIndex in an
  actor-isolated in-memory index; sub-millisecond queries on millions of files.
- **CLI** — single-shot (`deepfinder "q"`) + interactive REPL (readline, tab
  completion, `:stats`/`:open`/`:reveal`, persistent history), advanced syntax
  (boolean/wildcard/regex/path qualifiers), metadata filters, content search,
  duplicate finder. Distributed via Homebrew + man page + shell completions.
- **GUI** — Spotlight-style floating panel, Liquid Glass, Apple Intelligence glow,
  global hotkey (`⌃⌘K`), Quick Look, file detail panel, `⌘K` action panel.
- **Daemon + IPC** — background daemon holds the full index; CLI/GUI/HTTP/Shortcuts
  are thin clients over a Unix socket. SQLite WAL persistence, FSEvents live updates.
- **Media metadata** — image / audio / video / PDF extraction (on-demand in the GUI).
- **Services** — localhost HTTP search, `deepfinder://` URL scheme, Apple Shortcuts,
  AppleScript, `--serve` mode.
- **AI semantic search** — natural-language → search syntax, on-device Vision/Speech,
  result summarization, semantic grouping, optional cloud providers (DeepSeek / Qwen /
  Anthropic / Gemini, opt-in, metadata-only).

Status: **v3.0 → v3.2 all tagged.** See [`CHANGELOG.md`](CHANGELOG.md) for details.

---

## Next 📋 — Local RAG (v3.1, deferred)

On-device Retrieval-Augmented Generation: search the *contents* of your files by
meaning, with answers cited to specific files — all local, nothing leaves the Mac.

| REQ | Capability |
|-----|-----------|
| REQ-3.1-01 | File content chunking (256 tokens, 64 overlap; txt/md/pdf/docx/code) |
| REQ-3.1-02 | Local embedding engine (CoreML `MiniLM-L12-v2`, ~470 MB) |
| REQ-3.1-03 | Vector index storage (SQLite vec / hnswlib, 384-dim) |
| REQ-3.1-04 | Incremental embedding update (FSEvents-driven) |
| REQ-3.1-05 | Semantic search (query embedding → cosine Top-K) |
| REQ-3.1-06 | Local small-model generation (Llama 3.2 1B/3B via MLX) |
| REQ-3.1-07 | RAG Q&A (question detection, streaming answer, file citations) |

Status: **📋 planned, not started.** Scope is frozen in
[`reqs/v3.1-rag.md`](docs/superpowers/specs/reqs/v3.1-rag.md). On hold pending a
human decision on the CoreML/MLX model pipeline (model size vs. on-device speed
tradeoff). 7 of 158 total REQs.

---

## Later 💡 — exploratory

Directions being considered, **not yet committed** as REQs. Any of these may become
`v4.0` work after RAG lands:

- **Plugin / scripting extension** — user-authored search providers and actions.
- **Cross-device sync** of bookmarks, filters, and access history (end-to-end encrypted).
- **Broader macOS support** — evaluate back-porting to macOS 25 (Sequoia) to widen the
  install base.
- **Deeper content indexing** — code-symbol awareness, structured-data extraction
  (CSV/JSON schemas) building on the v3.1 chunking pipeline.

These live in [Discussions](https://github.com/nadav-cheung/DeepFinder/discussions)
until they become REQs.

---

## How requirements are tracked

- **Detailed specs**: [`docs/superpowers/specs/reqs/`](docs/superpowers/specs/reqs/) —
  158 REQs across 19 version modules, written as BDD user stories + Given/When/Then.
- **Status matrix**: [`REQ_STATUS.md`](docs/superpowers/specs/reqs/REQ_STATUS.md).
- **Change log**: [`REQ_CHANGE_LOG.md`](docs/superpowers/specs/REQ_CHANGE_LOG.md).
- **Architecture**: [`design/2026-05-26-deep-finder-design.md`](docs/superpowers/specs/design/2026-05-26-deep-finder-design.md).
