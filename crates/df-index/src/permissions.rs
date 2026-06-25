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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_granted_when_readable() {
        let tmp = tempfile::tempdir().unwrap();
        // read_dir on the tempdir itself succeeds → Granted.
        assert_eq!(
            classify(std::fs::read_dir(tmp.path())),
            Some(FdaState::Granted)
        );
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
