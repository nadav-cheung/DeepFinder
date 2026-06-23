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

/// One frame of the streamed response. The daemon sends `Batch`* then exactly
/// one terminal `Done` (or `Error`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ResponseFrame {
    Batch {
        paths: Vec<String>,
        meta: Vec<LiteMeta>,
        kind: Vec<MatchKind>,
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
}
