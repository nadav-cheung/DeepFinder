# Full Disk Access (TCC) Detection + Guidance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add proactive Full Disk Access (FDA) detection + user guidance to DeepFinder, replacing today's purely reactive "permission denied" warning with a probe-based check surfaced in `deepfind status`, a new `deepfind doctor`, and a daemon-startup log warning.

**Architecture:** A pure-ish probe `df_index::fda_state() -> FdaState { Granted, Denied, Unknown }` (readdir a known TCC-protected `~/Library` subdir; classify by errno) lives in `df-index` (keeps `df-core` I/O-free). The CLI (`deepfind`, same binary as the daemon) calls it from three places: `status` (report-only), `doctor` (TTY auto-opens the System Settings FDA pane + prints the exact binary path and a restart command), and `cmd_daemon` (one `tracing::warn!` on startup, no GUI). macOS cannot grant FDA programmatically — "auto-open" means opening the settings pane, not a consent dialog; the user still adds the binary manually.

**Tech Stack:** Rust workspace; `df-index` crate; clap CLI in `deepfind`; `std::fs::read_dir` + `std::io::IsTerminal` + `std::process::Command`; `tracing`. TDD with `tempfile`.

**Spec:** `docs/superpowers/specs/2026-06-25-permissions-design.md`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `crates/df-index/src/permissions.rs` | `FdaState` enum + `fda_state()` probe + private `classify`/`fda_state_with_home` test seams + unit tests | **Create** |
| `crates/df-index/src/lib.rs` | Declare module + re-export `FdaState`, `fda_state` | Modify (lines 19–29 area) |
| `crates/deepfind/src/main.rs` | CLI: `fda_status_word`/`should_open_panel` helpers; FDA line in `cmd_status`; new `Cmd::Doctor` + `cmd_doctor`; `warn_if_no_fda` in `cmd_daemon`; helper tests | Modify |
| `docs/architecture.md` | Add `doctor` to the §9 CLI command list | Modify |

Notes verified against current `main`:
- `deepfind` is the only `[[bin]]`; `deepfindd` is a lib linked into it (so the daemon and CLI share one FDA grant — local probe is authoritative).
- `std::io::IsTerminal` is already imported in `main.rs` (line 5).
- `launchd::LABEL == "cn.com.nadav.deepfind"` (pub const, `crates/deepfind/src/launchd.rs:13`), already used in `cmd_uninstall`.
- `df-index` already has `tempfile` as a dev-dependency (`Cargo.toml:22`).
- `df-core` stays pure — no edits there.
- **No `#[cfg(target_os = "macos")]` gating is needed** (a deliberate simplification vs. spec §7): off-macOS no `~/Library/*` dir is TCC-protected, so `fda_state()` naturally returns `Unknown`; the `Denied` branch in `cmd_doctor` (the only place `open`/`launchctl` appear) is therefore unreachable off-macOS, and a failed `open` there is already swallowed by `let _ =`. So the code is correct and no-op on Linux without cfg attributes.

---

## Task 1: `df-index` FDA probe module (`permissions.rs`)

**Files:**
- Create: `crates/df-index/src/permissions.rs`
- Modify: `crates/df-index/src/lib.rs` (declare + re-export)

- [ ] **Step 1: Write the failing tests + module skeleton (stub bodies)**

Create `crates/df-index/src/permissions.rs` with this exact content:

```rust
// SPDX-License-Identifier: MIT
//! macOS Full Disk Access (FDA) detection — heuristic `readdir` probe.
//!
//! Full Disk Access cannot be queried via a public TCC API nor granted
//! programmatically. We approximate the verdict by attempting to enumerate a
//! known TCC-protected user directory: with FDA `read_dir` succeeds, without it
//! the open fails with `PermissionDenied`. See
//! `docs/superpowers/specs/2026-06-25-permissions-design.md`.

use std::fs::ReadDir;
use std::io;
use std::path::{Path, PathBuf};

/// Heuristic verdict on whether the current process holds Full Disk Access.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FdaState {
    /// A protected dir was readable — FDA is in effect.
    Granted,
    /// A protected dir existed but `read_dir` returned `PermissionDenied`.
    Denied,
    /// No candidate existed / non-macOS / indeterminate.
    Unknown,
}

/// Known TCC-protected `~/Library` subdirectories. Without FDA, opening any of
/// these fails with `PermissionDenied`; with FDA, `read_dir` succeeds. The list
/// hedges against a dir being absent (e.g. Mail not configured) — the first
/// existing candidate decides. Exact ordering is validated on real macOS.
const PROBE_CANDIDATES: &[&str] = &[
    "Library/Calendars",
    "Library/Mail",
    "Library/Messages",
    "Library/Safari",
    "Library/Metadata/CoreData",
];

/// STUB — real body added in Step 3.
fn classify(_outcome: io::Result<ReadDir>) -> Option<FdaState> {
    None
}

/// STUB — real body added in Step 3.
fn fda_state_with_home(_home: Option<&Path>) -> FdaState {
    FdaState::Unknown
}

/// Probe whether the current process holds Full Disk Access by enumerating a
/// known TCC-protected directory. One `read_dir`; no side effects. Returns
/// [`FdaState::Unknown`] on non-macOS or when no candidate exists.
pub fn fda_state() -> FdaState {
    FdaState::Unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_granted_when_readable() {
        let tmp = tempfile::tempdir().unwrap();
        // read_dir on the tempdir itself succeeds → Granted.
        assert_eq!(classify(std::fs::read_dir(tmp.path())), Some(FdaState::Granted));
    }

    #[test]
    fn classify_denied_when_permission_denied() {
        let err = io::Error::new(io::ErrorKind::PermissionDenied, "denied");
        assert_eq!(classify(Err(err)), Some(FdaState::Denied));
    }

    #[test]
    fn classify_skip_when_not_found() {
        let err = io::Error::new(io::ErrorKind::NotFound, "missing");
        assert_eq!(classify(Err(err)), None);
    }

    #[test]
    fn fda_state_with_home_granted_when_candidate_readable() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("Library/Calendars")).unwrap();
        assert_eq!(fda_state_with_home(Some(tmp.path())), FdaState::Granted);
    }

    #[test]
    fn fda_state_with_home_unknown_when_no_candidate() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(fda_state_with_home(Some(tmp.path())), FdaState::Unknown);
    }

    #[test]
    fn fda_state_with_home_unknown_when_home_none() {
        assert_eq!(fda_state_with_home(None), FdaState::Unknown);
    }
}
```

In `crates/df-index/src/lib.rs`, add the module declaration and re-exports. Insert after line 23 (`pub mod registry;`) so the `pub mod` block stays together:

```rust
pub mod permissions;
```

And add to the `pub use` block (after line 29, `pub use registry::...`):

```rust
pub use permissions::{fda_state, FdaState};
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p df-index permissions`
Expected: FAIL — `classify_granted_when_readable` expects `Some(Granted)` but stub returns `None`; `classify_denied_when_permission_denied` expects `Some(Denied)` but stub returns `None`; `fda_state_with_home_granted_when_candidate_readable` expects `Granted` but stub returns `Unknown`. (3 failures; the `Unknown`/`skip`/`home_none` tests pass already.)

- [ ] **Step 3: Write the real implementation**

In `crates/df-index/src/permissions.rs`, replace the three STUB bodies with:

```rust
/// Classify a single candidate's `read_dir` outcome.
/// `None` means "not decisive — try the next candidate".
fn classify(outcome: io::Result<ReadDir>) -> Option<FdaState> {
    match outcome {
        Ok(_) => Some(FdaState::Granted),
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => Some(FdaState::Denied),
        Err(_) => None,
    }
}

/// Like [`fda_state`] but with an explicit home directory (testable seam).
fn fda_state_with_home(home: Option<&Path>) -> FdaState {
    let Some(home) = home else {
        return FdaState::Unknown;
    };
    for cand in PROBE_CANDIDATES {
        if let Some(state) = classify(std::fs::read_dir(home.join(cand))) {
            return state;
        }
    }
    FdaState::Unknown
}

/// Probe whether the current process holds Full Disk Access by enumerating a
/// known TCC-protected directory. One `read_dir`; no side effects. Returns
/// [`FdaState::Unknown`] on non-macOS or when no candidate exists.
pub fn fda_state() -> FdaState {
    fda_state_with_home(std::env::var_os("HOME").map(PathBuf::from).as_deref())
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p df-index permissions`
Expected: PASS — all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add crates/df-index/src/permissions.rs crates/df-index/src/lib.rs
git commit -m "feat(index): add fda_state() Full Disk Access probe (Granted/Denied/Unknown)"
```

---

## Task 2: CLI status line + pure helpers

**Files:**
- Modify: `crates/deepfind/src/main.rs` (add two helper fns; add one line to `cmd_status`; add tests to the existing `mod tests` at line 905)

- [ ] **Step 1: Write the failing tests**

In `crates/deepfind/src/main.rs`, inside the existing `#[cfg(test)] mod tests` block (starts at line 905, `use super::*;` on 907), append these two tests before the closing `}` (after the `index_state_stale_when_old` test, before line 972 `}`):

```rust
    #[test]
    fn fda_status_word_maps_states() {
        assert_eq!(fda_status_word(df_index::FdaState::Granted), "granted");
        assert_eq!(fda_status_word(df_index::FdaState::Denied), "missing");
        assert_eq!(fda_status_word(df_index::FdaState::Unknown), "unknown");
    }

    #[test]
    fn should_open_panel_only_when_denied_and_tty() {
        assert!(should_open_panel(df_index::FdaState::Denied, true));
        assert!(!should_open_panel(df_index::FdaState::Denied, false));
        assert!(!should_open_panel(df_index::FdaState::Granted, true));
        assert!(!should_open_panel(df_index::FdaState::Unknown, true));
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p deepfind --bin deepfind -- fda_status_word should_open_panel`
Expected: FAIL — compile error: `cannot find function fda_status_word` / `should_open_panel` (they don't exist yet).

- [ ] **Step 3: Add the helper functions**

In `crates/deepfind/src/main.rs`, add these two functions immediately above `async fn cmd_status()` (currently at line 553):

```rust
/// One-word FDA status for the `status` line.
fn fda_status_word(state: df_index::FdaState) -> &'static str {
    match state {
        df_index::FdaState::Granted => "granted",
        df_index::FdaState::Denied => "missing",
        df_index::FdaState::Unknown => "unknown",
    }
}

/// Whether `doctor` should auto-open the Full Disk Access settings pane — only
/// when FDA is missing AND stdout is an interactive terminal (don't pop System
/// Settings from scripts/CI).
fn should_open_panel(state: df_index::FdaState, is_tty: bool) -> bool {
    matches!(state, df_index::FdaState::Denied) && is_tty
}
```

- [ ] **Step 4: Wire the FDA line into `cmd_status`**

In `async fn cmd_status()`, add the FDA line immediately after the daemon-reachable `match` block (after line 558, before `let db = default_db();`). Insert:

```rust
    println!(
        "full disk access: {}",
        fda_status_word(df_index::fda_state())
    );
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p deepfind --bin deepfind -- fda_status_word should_open_panel`
Expected: PASS — both new tests pass.

- [ ] **Step 6: Commit**

```bash
git add crates/deepfind/src/main.rs
git commit -m "feat(cli): show Full Disk Access state in `deepfind status`"
```

---

## Task 3: `deepfind doctor` subcommand

**Files:**
- Modify: `crates/deepfind/src/main.rs` (add `Cmd::Doctor` variant, match arm, `cmd_doctor` fn)

> No new unit test: `cmd_doctor` does I/O (print + `open`); its only decision — whether to open — is already covered by `should_open_panel` (Task 2). Verified by manual run in Step 4.

- [ ] **Step 1: Add the `Doctor` subcommand variant**

In `crates/deepfind/src/main.rs`, in `enum Cmd`, add the variant immediately after the `Status` variant (after line 69 `Status,`):

```rust
    /// Self-diagnostic (Full Disk Access check + guidance).
    Doctor,
```

- [ ] **Step 2: Add the match arm**

In `async fn main()` (the `match cli.cmd` block), add the arm immediately after `Cmd::Status => cmd_status().await,` (line 213):

```rust
        Cmd::Doctor => cmd_doctor(),
```

- [ ] **Step 3: Implement `cmd_doctor`**

In `crates/deepfind/src/main.rs`, add this function immediately after `async fn cmd_status()` ends (after line 587):

```rust
/// Self-diagnostic. Today: Full Disk Access probe + guidance.
fn cmd_doctor() {
    let state = df_index::fda_state();
    match state {
        df_index::FdaState::Granted => println!("✅ Full Disk Access: granted"),
        df_index::FdaState::Denied => {
            println!("❌ Full Disk Access: missing");
            println!();
            println!(
                "Without it, protected dirs (~/Library/Mail, Messages, Safari, …) are skipped."
            );
            let exe = std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "deepfind (run `which deepfind` to locate)".to_string());
            println!("Binary to authorize: {exe}");
            if should_open_panel(state, std::io::stdout().is_terminal()) {
                println!("Opening Full Disk Access settings…");
                let _ = std::process::Command::new("open")
                    .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    .status();
            } else {
                println!("Open: System Settings → Privacy & Security → Full Disk Access");
            }
            println!();
            println!("After granting, restart the daemon:");
            println!("    launchctl kickstart -k gui/$(id -u)/{}", launchd::LABEL);
        }
        df_index::FdaState::Unknown => {
            println!("❓ Full Disk Access: unknown (no protected dir could be probed).");
            println!("If searches miss files under ~/Library, grant Full Disk Access.");
        }
    }
}
```

- [ ] **Step 4: Build and manually verify**

Run: `cargo build -p deepfind`
Expected: builds clean.

Then (manual, on macOS): `./target/debug/deepfind doctor`
Expected: prints one of `✅ Full Disk Access: granted` / `❌ … missing` (+ guidance; opens System Settings if a TTY and missing) / `❓ … unknown`. Use `./target/debug/deepfind doctor | cat` to confirm the non-TTY branch prints "Open: System Settings → …" without launching the GUI.

- [ ] **Step 5: Commit**

```bash
git add crates/deepfind/src/main.rs
git commit -m "feat(cli): add `deepfind doctor` (FDA check + guidance, TTY auto-opens settings)"
```

---

## Task 4: Daemon-startup Full Disk Access warning

**Files:**
- Modify: `crates/deepfind/src/main.rs` (add `warn_if_no_fda`; call it in `cmd_daemon`)

- [ ] **Step 1: Add the warning helper and call it on startup**

In `crates/deepfind/src/main.rs`, add this function immediately above `async fn cmd_daemon()` (currently at line 540):

```rust
/// At daemon start, warn once if Full Disk Access is missing. No GUI — the
/// daemon must not pop System Settings. Guides the user to `deepfind doctor`.
fn warn_if_no_fda() {
    if matches!(df_index::fda_state(), df_index::FdaState::Denied) {
        tracing::warn!(
            "Full Disk Access not granted; protected dirs (~/Library/Mail, Messages, …) \
             will be skipped. Run `deepfind doctor`."
        );
    }
}
```

Then in `async fn cmd_daemon()`, call it immediately after `.init();` (after line 546) and before the `deepfindd::serve(...)` call:

```rust
    warn_if_no_fda();
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cargo build -p deepfind`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add crates/deepfind/src/main.rs
git commit -m "feat(daemon): warn at startup when Full Disk Access is missing"
```

---

## Task 5: Docs accuracy + full build gates

**Files:**
- Modify: `docs/architecture.md` §9 (CLI command list)

- [ ] **Step 1: Add `doctor` to the §9 CLI command list**

In `docs/architecture.md`, in the §9 code block, change:

```
deepfind status
deepfind db      add <name> <root> [--max-file-size N]
```

to:

```
deepfind status
deepfind doctor                 # self-diagnostic: Full Disk Access check + guidance
deepfind db      add <name> <root> [--max-file-size N]
```

- [ ] **Step 2: Run all project build gates (must all pass before commit)**

Run each; expect success:
```bash
cargo fmt --check
cargo clippy --workspace --all-targets -D warnings
cargo test --workspace
```
Expected: fmt clean; clippy zero warnings; all tests pass (the 6 new `permissions` tests + 2 new CLI helper tests, plus the pre-existing suite).

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md
git commit -m "docs(architecture): list `deepfind doctor` in CLI surface"
```

---

## Done criteria

- `df_index::fda_state()` exists, returns `FdaState`, unit-tested (6 tests).
- `deepfind status` prints a `full disk access: granted|missing|unknown` line.
- `deepfind doctor` probes FDA; on missing (TTY) opens System Settings and prints the binary path + `launchctl kickstart` restart command; non-TTY prints instructions only.
- The daemon logs one `tracing::warn!` at startup when FDA is `Denied`.
- `df-core` untouched (still pure).
- `cargo fmt --check` · `cargo clippy --workspace --all-targets -D warnings` · `cargo test --workspace` all green.
