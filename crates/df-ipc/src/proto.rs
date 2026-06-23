// SPDX-License-Identifier: MIT
//! Protocol messages (serde + bincode on the wire; framing added in Step 3).

use std::path::PathBuf;

use df_core::LiteMeta;
use serde::{Deserialize, Serialize};

/// How a result matched: by filename, content, or both.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum MatchKind {
    Filename,
    Content,
    Both,
}

/// A single content match rendered for grep-style output (`path:line:text`).
/// Streamed via [`ResponseFrame::Lines`] when `-n`/`-C` is requested.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LineHit {
    pub path: String,
    pub line_no: u32,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchRequest {
    pub query: String,
    /// Restrict search to a subtree.
    pub scope: Option<PathBuf>,
    pub limit: Option<u32>,
    pub opts: SearchOptions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchOptions {
    /// Force online `--direct` scan (skip the daemon/index).
    #[serde(default)]
    pub direct: bool,
    /// `-e`: keep only these extensions (no leading dot), e.g. ["rs","md"].
    #[serde(default)]
    pub extensions: Vec<String>,
    /// `-t`: keep only these type categories, e.g. ["code","docs"].
    #[serde(default)]
    pub types: Vec<String>,
    /// `-E`: exclude glob patterns (matched against the full path).
    #[serde(default)]
    pub excludes: Vec<String>,
    /// `-g`: inclusive glob patterns — a path must match at least one.
    #[serde(default)]
    pub globs: Vec<String>,
    /// `-d`: max path depth (separator count from the index root; `./` stripped).
    #[serde(default)]
    pub max_depth: Option<u32>,
    /// `--regex`: treat the query as a regex matched against paths (filename
    /// regex mode; the longest literal atom in the regex drives candidate gen,
    /// then regex.is_match verifies).
    #[serde(default)]
    pub regex: Option<String>,
    /// Case-sensitivity control (`-i` / `-s`; default smart-case).
    #[serde(default)]
    pub case: CaseControl,
    /// `-n`: report content matches with line numbers (`path:line:text`).
    #[serde(default)]
    pub line_numbers: bool,
    /// `-C N`: show N lines of context around each content match.
    #[serde(default)]
    pub context: Option<u32>,
    /// `--content` / `--filename`: which layers to query (default: both).
    #[serde(default)]
    pub layers: LayerMask,
    /// `-p` (full path) / `-b` (basename only) match mode (default: full path).
    #[serde(default)]
    pub path_mode: PathMode,
    /// `-H`: include hidden files (only affects `--direct`; indexed search reflects
    /// what was built).
    #[serde(default)]
    pub hidden: bool,
    /// `--sort`: result ordering (default: kind-weight + depth + path).
    #[serde(default)]
    pub sort: SortMode,
}

/// Which layers a query touches (default both; `#[serde(default)]` ⇒ BOTH for old
/// clients that omit the field).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LayerMask {
    #[serde(default = "default_true")]
    pub filename: bool,
    #[serde(default = "default_true")]
    pub content: bool,
}

fn default_true() -> bool {
    true
}

impl Default for LayerMask {
    fn default() -> Self {
        LayerMask {
            filename: true,
            content: true,
        }
    }
}

/// Filename match mode: full path (default) or basename only.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum PathMode {
    #[default]
    Full,
    Basename,
}

/// Result ordering. `Default` = match-kind weight + path depth + path (best
/// matches first, deterministic).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SortMode {
    #[default]
    Default,
    Path,
    Kind,
    None,
}

/// Case-sensitivity control for a search (fd/ripgrep-style).
///
/// - `Smart` (default): case-insensitive unless the query contains an ASCII
///   uppercase letter, in which case it is case-sensitive.
/// - `Insensitive` (`-i`): always case-insensitive.
/// - `Sensitive` (`-s`): always case-sensitive.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum CaseControl {
    #[default]
    Smart,
    Insensitive,
    Sensitive,
}

impl CaseControl {
    /// Resolve to an effective case-sensitive flag for `pattern` (the raw user
    /// query / regex). Smart-case treats any ASCII uppercase letter in the
    /// pattern as a request for case-sensitive matching.
    pub fn sensitive(self, pattern: &str) -> bool {
        match self {
            CaseControl::Sensitive => true,
            CaseControl::Insensitive => false,
            CaseControl::Smart => pattern.bytes().any(|b| b.is_ascii_uppercase()),
        }
    }
}

/// One frame of the streamed response. The daemon sends `Batch`* (or `Lines`*
/// for `-n`/`-C` content-line output) then exactly one terminal `Done` (or
/// `Error`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ResponseFrame {
    Batch {
        paths: Vec<String>,
        meta: Vec<LiteMeta>,
        kind: Vec<MatchKind>,
    },
    /// Content matches as grep-style line hits (`-n` / `-C`). Sent instead of
    /// `Batch` when line-number output is requested.
    Lines {
        hits: Vec<LineHit>,
    },
    Done {
        total: u32,
    },
    Error {
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::CaseControl as C;
    use super::SearchOptions;
    use super::{LayerMask, PathMode, SortMode};

    #[test]
    fn smart_case_resolution() {
        // No uppercase → case-insensitive.
        assert!(!C::Smart.sensitive("foo"));
        assert!(!C::Smart.sensitive(""));
        assert!(!C::Smart.sensitive("main.rs"));
        // Any ASCII uppercase → case-sensitive.
        assert!(C::Smart.sensitive("Foo"));
        assert!(C::Smart.sensitive("README"));
        assert!(C::Smart.sensitive("index.MD"));
    }

    #[test]
    fn explicit_case_overrides_smart() {
        assert!(C::Sensitive.sensitive("foo")); // -s forces sensitive even on lowercase
        assert!(!C::Insensitive.sensitive("Foo")); // -i forces insensitive even on uppercase
    }

    #[test]
    fn line_options_default_and_roundtrip() {
        let opts = SearchOptions::default();
        assert!(!opts.line_numbers);
        assert_eq!(opts.context, None);

        let opts = SearchOptions {
            line_numbers: true,
            context: Some(2),
            ..Default::default()
        };
        let bytes = bincode::serde::encode_to_vec(&opts, bincode::config::standard()).unwrap();
        let back: SearchOptions =
            bincode::serde::decode_from_slice(&bytes, bincode::config::standard())
                .unwrap()
                .0;
        assert!(back.line_numbers);
        assert_eq!(back.context, Some(2));
    }

    #[test]
    fn b_options_default_and_roundtrip() {
        // Defaults: both layers, full-path mode, no hidden, default sort.
        let opts = SearchOptions::default();
        assert_eq!(
            opts.layers,
            LayerMask {
                filename: true,
                content: true
            }
        );
        assert_eq!(opts.path_mode, PathMode::Full);
        assert!(!opts.hidden);
        assert_eq!(opts.sort, SortMode::Default);

        let opts = SearchOptions {
            layers: LayerMask {
                filename: false,
                content: true,
            },
            path_mode: PathMode::Basename,
            hidden: true,
            sort: SortMode::Path,
            ..Default::default()
        };
        let bytes = bincode::serde::encode_to_vec(&opts, bincode::config::standard()).unwrap();
        let back: SearchOptions =
            bincode::serde::decode_from_slice(&bytes, bincode::config::standard())
                .unwrap()
                .0;
        assert_eq!(
            back.layers,
            LayerMask {
                filename: false,
                content: true
            }
        );
        assert_eq!(back.path_mode, PathMode::Basename);
        assert!(back.hidden);
        assert_eq!(back.sort, SortMode::Path);
    }
}
