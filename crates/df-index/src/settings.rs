// SPDX-License-Identifier: MIT
//! Global settings file (`<data_dir>/settings.json`). The first and (for now)
//! only field is `ignore`: a list of gitignore-glob patterns unioned into every
//! index build, `--direct` scan, and df-watch event. The schema is extensible —
//! every field is `#[serde(default)]`, so unknown future keys are ignored on
//! read and missing keys default (forward/backward compatible, same convention
//! as `SearchOptions`).
//!
//! Absent / unreadable / malformed file ⇒ [`Settings::default`] + a
//! `tracing::warn!` — a build/scan never fails over a bad config.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::Result;

/// The on-disk `settings.json` shape.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Settings {
    /// gitignore-glob patterns to skip at every walk/scan (union with the
    /// built-in `DEFAULT_SKIP` and the `ignore` crate's `standard_filters`).
    #[serde(default)]
    pub ignore: Vec<String>,
}

impl Settings {
    /// `<data_dir>/settings.json`.
    pub fn settings_path(data_dir: &Path) -> PathBuf {
        data_dir.join("settings.json")
    }

    /// Load settings from `<data_dir>/settings.json`. Returns
    /// [`Settings::default`] (empty `ignore`) when the file is missing (a fresh
    /// install), and default + `tracing::warn!` when it is unreadable or
    /// malformed JSON — a build/scan never aborts over a bad config.
    pub fn load(data_dir: &Path) -> Settings {
        let path = Self::settings_path(data_dir);
        let raw = match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Settings::default();
            }
            Err(e) => {
                tracing::warn!(error = %e, path = ?path, "settings.json unreadable; using defaults");
                return Settings::default();
            }
        };
        match serde_json::from_str::<Settings>(&raw) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(error = %e, path = ?path, "settings.json malformed; using defaults");
                Settings::default()
            }
        }
    }

    /// Serialize + atomically write to `<data_dir>/settings.json` (tmp → fsync →
    /// rename; same helper [`registry`] uses).
    ///
    /// [`registry`]: crate::registry
    pub fn save(data_dir: &Path, settings: &Settings) -> Result<()> {
        let s = serde_json::to_vec_pretty(settings)
            .map_err(|e| crate::IndexError::Other(format!("settings encode: {e}")))?;
        crate::atomic_write_public(&Self::settings_path(data_dir), &s)
    }

    /// Append `pattern` to `ignore` unless already present (exact-match dedup).
    /// Idempotent.
    pub fn add_ignore(&mut self, pattern: &str) {
        if !self.ignore.iter().any(|p| p == pattern) {
            self.ignore.push(pattern.to_string());
        }
    }

    /// Remove `pattern` from `ignore` (exact match). Returns `true` if it was
    /// present.
    pub fn remove_ignore(&mut self, pattern: &str) -> bool {
        let before = self.ignore.len();
        self.ignore.retain(|p| p != pattern);
        self.ignore.len() != before
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_missing_is_default() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Settings::load(tmp.path());
        assert!(s.ignore.is_empty());
    }

    #[test]
    fn save_load_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let s = Settings {
            ignore: vec!["node_modules".into(), "*.log".into()],
        };
        Settings::save(tmp.path(), &s).unwrap();
        assert_eq!(Settings::load(tmp.path()), s);
    }

    #[test]
    fn load_malformed_is_default() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(Settings::settings_path(tmp.path()), b"{ broken").unwrap();
        assert!(Settings::load(tmp.path()).ignore.is_empty());
    }

    #[test]
    fn serde_unknown_key_ignored() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(
            Settings::settings_path(tmp.path()),
            b"{\"ignore\":[\"foo\"],\"future_field\":42}",
        )
        .unwrap();
        assert_eq!(Settings::load(tmp.path()).ignore, vec!["foo".to_string()]);
    }

    #[test]
    fn serde_missing_ignore_key_defaults() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(Settings::settings_path(tmp.path()), b"{}").unwrap();
        assert!(Settings::load(tmp.path()).ignore.is_empty());
    }

    #[test]
    fn add_ignore_dedup() {
        let mut s = Settings {
            ignore: vec!["foo".into()],
        };
        s.add_ignore("foo");
        s.add_ignore("bar");
        assert_eq!(s.ignore, vec!["foo".to_string(), "bar".to_string()]);
    }

    #[test]
    fn remove_ignore_exact_match() {
        let mut s = Settings {
            ignore: vec!["foo".into(), "bar".into()],
        };
        assert!(s.remove_ignore("foo"));
        assert!(!s.remove_ignore("missing"));
        assert_eq!(s.ignore, vec!["bar".to_string()]);
    }
}
