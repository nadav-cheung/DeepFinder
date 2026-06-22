// SPDX-License-Identifier: MIT
//! Subtree (`--scope`) membership test. Pure string/path logic — no I/O — so
//! it is shared by the daemon (filters indexed results) and the CLI
//! (`--direct` walk root). A leading `./` is stripped from both sides before a
//! component-wise prefix comparison, so an index built from `.` matches a
//! `--scope ./src` (or `src`) request.

use std::path::Path;

fn strip_dot(s: &str) -> &str {
    s.strip_prefix("./").unwrap_or(s)
}

/// True if `path` falls under `scope`. `None` (or empty/non-UTF-8) scope ⇒ all
/// paths match.
pub fn in_scope(path: &str, scope: Option<&Path>) -> bool {
    let Some(scope) = scope else {
        return true;
    };
    let Some(scope_s) = scope.to_str() else {
        return true;
    };
    let scope_s = strip_dot(scope_s);
    if scope_s.is_empty() {
        return true;
    }
    let path_s = strip_dot(path);
    Path::new(path_s).starts_with(Path::new(scope_s))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn none_scope_matches_all() {
        assert!(in_scope("/anything", None));
    }

    #[test]
    fn component_prefix() {
        assert!(in_scope("src/lib.rs", Some(Path::new("src"))));
        assert!(!in_scope("srcx/lib.rs", Some(Path::new("src"))));
        assert!(in_scope("src/nested/x.rs", Some(Path::new("src"))));
    }

    #[test]
    fn strips_leading_dot() {
        assert!(in_scope("./src/a.rs", Some(Path::new("./src"))));
        assert!(in_scope("./src/a.rs", Some(Path::new("src"))));
    }
}
