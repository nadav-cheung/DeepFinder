// SPDX-License-Identifier: MIT
//! Result filters shared by the daemon and the CLI (`--direct` path): extension,
//! type category, exclude-glob. Pure path logic — no engine involvement — so both
//! layers (filename + content) are filtered uniformly after merging.

use std::path::Path;

use crate::proto::SearchOptions;

/// fd-style type categories → extensions (no leading dot).
pub fn type_extensions(category: &str) -> Option<&'static [&'static str]> {
    Some(match category {
        "code" => &[
            "rs", "go", "py", "js", "mjs", "cjs", "ts", "jsx", "tsx", "c", "h", "cpp", "cc", "cxx",
            "hpp", "hh", "java", "kt", "kts", "scala", "rb", "pl", "pm", "php", "swift", "m", "mm",
            "sh", "bash", "zsh", "fish", "lua", "r", "jl", "ex", "exs", "erl", "hs", "lhs", "ml",
            "mli", "clj", "cljs", "cljc", "vim", "el", "lisp", "scm", "sql",
        ],
        "docs" => &[
            "md", "markdown", "rst", "txt", "tex", "adoc", "asciidoc", "org", "pdf",
        ],
        "config" => &[
            "toml", "yaml", "yml", "json", "json5", "ini", "cfg", "conf", "xml", "env",
        ],
        "web" => &[
            "html", "htm", "css", "scss", "sass", "less", "vue", "svelte",
        ],
        "archive" => &[
            "zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "lz",
        ],
        "media" => &[
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "svg", "ico", "webp", "mp3", "wav",
            "flac", "aac", "ogg", "mp4", "mkv", "webm", "avi", "mov", "m4a", "m4v",
        ],
        _ => return None,
    })
}

/// Minimal glob match (`*` = any run, `?` = one char). Matched against `text`.
pub fn glob_matches(pattern: &str, text: &str) -> bool {
    glob_impl(pattern.as_bytes(), text.as_bytes())
}

fn glob_impl(pat: &[u8], text: &[u8]) -> bool {
    let (mut pi, mut ti) = (0usize, 0usize);
    let (mut star_pi, mut star_ti): (Option<usize>, usize) = (None, 0);
    while ti < text.len() {
        if pi < pat.len() && (pat[pi] == b'?' || pat[pi] == text[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < pat.len() && pat[pi] == b'*' {
            star_pi = Some(pi);
            star_ti = ti;
            pi += 1;
        } else if let Some(sp) = star_pi {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while pi < pat.len() && pat[pi] == b'*' {
        pi += 1;
    }
    pi == pat.len()
}

/// True if `path` passes every active filter in `opts`.
pub fn passes(path: &str, opts: &SearchOptions) -> bool {
    if !opts.extensions.is_empty() {
        let ext = ext_of(path);
        if !opts.extensions.iter().any(|e| e == ext) {
            return false;
        }
    }
    if !opts.types.is_empty() {
        let ext = ext_of(path);
        let in_type = opts
            .types
            .iter()
            .any(|t| type_extensions(t).is_some_and(|exts| exts.contains(&ext)));
        if !in_type {
            return false;
        }
    }
    // Globs/excludes match against the raw path OR the `./`-stripped path, so a
    // user pattern like `docs/*` excludes `./docs/readme.md`.
    let norm = path.strip_prefix("./").unwrap_or(path);
    let gmatch = |pat: &str| glob_matches(pat, path) || glob_matches(pat, norm);
    for pat in &opts.excludes {
        if gmatch(pat) {
            return false;
        }
    }
    if !opts.globs.is_empty() && !opts.globs.iter().any(|g| gmatch(g)) {
        return false;
    }
    if let Some(maxd) = opts.max_depth {
        if depth_of(path) > maxd {
            return false;
        }
    }
    true
}

/// Path depth = separator count from the index root (a leading `./` is stripped).
fn depth_of(path: &str) -> u32 {
    let p = path.strip_prefix("./").unwrap_or(path);
    p.matches('/').count() as u32
}

/// Extract the longest run of literal (non-metacharacter) characters from a
/// regex string, to drive trigram candidate generation in filename-regex mode.
/// Strips escapes, character classes, groups, quantifiers, anchors, and `.`.
/// Returns None if there is no literal run.
pub fn longest_literal_atom(regex: &str) -> Option<String> {
    let mut best: Vec<char> = Vec::new();
    let mut cur: Vec<char> = Vec::new();
    let mut chars = regex.chars().peekable();
    let mut in_class = false;
    while let Some(c) = chars.next() {
        if in_class {
            if c == '\\' {
                chars.next();
            } else if c == ']' {
                in_class = false;
            }
            flush_run(&mut cur, &mut best);
            continue;
        }
        match c {
            '\\' => {
                chars.next();
                flush_run(&mut cur, &mut best);
            }
            '[' => {
                flush_run(&mut cur, &mut best);
                in_class = true;
            }
            '(' | ')' | '|' | '*' | '+' | '?' | '^' | '$' | '.' => flush_run(&mut cur, &mut best),
            '{' => {
                for nc in chars.by_ref() {
                    if nc == '}' {
                        break;
                    }
                }
                flush_run(&mut cur, &mut best);
            }
            _ => cur.push(c),
        }
    }
    flush_run(&mut cur, &mut best);
    if best.is_empty() {
        None
    } else {
        Some(best.into_iter().collect())
    }
}

fn flush_run(cur: &mut Vec<char>, best: &mut Vec<char>) {
    if cur.len() > best.len() {
        std::mem::swap(best, cur);
    }
    cur.clear();
}

fn ext_of(path: &str) -> &str {
    Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(ext: &[&str], types: &[&str], exc: &[&str]) -> SearchOptions {
        SearchOptions {
            direct: false,
            extensions: ext.iter().map(|s| s.to_string()).collect(),
            types: types.iter().map(|s| s.to_string()).collect(),
            excludes: exc.iter().map(|s| s.to_string()).collect(),
            globs: vec![],
            max_depth: None,
            regex: None,
            case: Default::default(),
        }
    }

    #[test]
    fn extension_filter() {
        let o = opts(&["rs", "md"], &[], &[]);
        assert!(passes("/a/b.rs", &o));
        assert!(passes("/a/b.md", &o));
        assert!(!passes("/a/b.txt", &o));
        assert!(!passes("/a/b", &o)); // no extension
    }

    #[test]
    fn type_filter() {
        let o = opts(&[], &["code"], &[]);
        assert!(passes("/x/main.rs", &o));
        assert!(!passes("/x/readme.md", &o));
        let o = opts(&[], &["docs"], &[]);
        assert!(passes("/x/readme.md", &o));
    }

    #[test]
    fn exclude_glob() {
        let o = opts(&[], &[], &["*/target/*", "*.log"]);
        assert!(!passes("/proj/target/debug/x", &o));
        assert!(!passes("/proj/a.log", &o));
        assert!(passes("/proj/src/main.rs", &o));
    }

    #[test]
    fn glob_matches_dot_prefix() {
        // A `./`-prefixed stored path must still match a pattern without the prefix.
        let o = opts(&[], &[], &["docs/*"]);
        assert!(!passes("./docs/readme.md", &o));
        assert!(passes("./src/main.rs", &o));
        let o = SearchOptions {
            globs: vec!["src/*".to_string()],
            ..opts(&[], &[], &[])
        };
        assert!(passes("./src/main.rs", &o));
        assert!(!passes("./docs/readme.md", &o));
    }

    #[test]
    fn glob_matcher() {
        assert!(glob_matches("*.rs", "a.rs"));
        assert!(!glob_matches("*.{rs}", "a.rs")); // no brace expansion; '{' is literal
        assert!(!glob_matches("*.rs", "a.go"));
        assert!(glob_matches("foo?bar", "fooXbar"));
        assert!(glob_matches("*", "anything"));
    }

    #[test]
    fn longest_atom() {
        assert_eq!(longest_literal_atom("foo.*bar"), Some("foo".to_string()));
        assert_eq!(
            longest_literal_atom("config\\.rs"),
            Some("config".to_string())
        );
        assert_eq!(longest_literal_atom("\\d+"), None);
        assert_eq!(longest_literal_atom("[a-z]main"), Some("main".to_string()));
        assert_eq!(longest_literal_atom("a|bb|ccc"), Some("ccc".to_string()));
    }
}
