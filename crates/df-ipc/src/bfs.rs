// SPDX-License-Identifier: MIT
//! bfs/find-style expression language (`--expr`): an advanced filter that
//! coexists with `-e/-t/-E/-g/-d`. Grammar (precedence `!` > `-a` > `-o`, with
//! implicit AND between adjacent factors):
//!
//! ```text
//! or   := and ( -o and )*
//! and  := factor ( (-a)? factor )*       // implicit AND
//! fact := ! factor | ( or ) | prim
//! prim := -name PAT | -path PAT | -size [+|-]N[c|k|M|G] | -newer FILE
//! ```
//!
//! Pure parser + evaluator over `(path, LiteMeta)`; `-newer FILE`'s mtime is
//! resolved (I/O) by the caller and supplied via a closure. `-links` is NOT
//! supported (LiteMeta carries no link count).

use std::path::Path;

use df_core::LiteMeta;

use crate::filter::glob_matches;

/// Numeric comparison sense for `-size`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cmp {
    Eq,
    Gt,
    Lt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Prim {
    /// `-name PAT` — glob on the file's base name.
    Name(String),
    /// `-path PAT` — glob on the full path.
    Path(String),
    /// `-size CMP N` — byte size comparison (N already scaled to bytes).
    Size(Cmp, i64),
    /// `-newer FILE` — mtime newer than FILE's mtime (resolved by the caller).
    Newer(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Expr {
    Prim(Prim),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Not(Box<Expr>),
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Parse a bfs expression. Returns `Err` with a message on malformed input.
pub fn parse(input: &str) -> Result<Expr, String> {
    let toks: Vec<&str> = input.split_whitespace().collect();
    let mut p = Parser { toks, pos: 0 };
    let node = p.parse_or()?;
    if p.pos != p.toks.len() {
        return Err(format!("unexpected trailing token: '{}'", p.toks[p.pos]));
    }
    Ok(node)
}

struct Parser<'a> {
    toks: Vec<&'a str>,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a str> {
        self.toks.get(self.pos).copied()
    }
    fn bump(&mut self) -> Option<&'a str> {
        let t = self.toks.get(self.pos).copied();
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn parse_or(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_and()?;
        while matches!(self.peek(), Some(t) if t == "-o" || t == "-or") {
            self.bump();
            let right = self.parse_and()?;
            left = Expr::Or(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_and(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_factor()?;
        loop {
            match self.peek() {
                Some(t) if t == "-a" || t == "-and" => {
                    self.bump();
                }
                // implicit AND: another factor starts here
                Some(t) if is_factor_start(t) => {}
                _ => break,
            }
            let right = self.parse_factor()?;
            left = Expr::And(Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn parse_factor(&mut self) -> Result<Expr, String> {
        let head = self.bump();
        match head {
            None => Err("unexpected end of expression".into()),
            Some("!") | Some("-not") => {
                let f = self.parse_factor()?;
                Ok(Expr::Not(Box::new(f)))
            }
            Some("(") => {
                let e = self.parse_or()?;
                match self.bump() {
                    Some(")") => Ok(e),
                    other => Err(format!("expected ')', got {:?}", other)),
                }
            }
            Some(t) if t.starts_with('-') => self.parse_prim(t),
            other => Err(format!("unexpected token {:?}", other)),
        }
    }

    fn parse_prim(&mut self, head: &str) -> Result<Expr, String> {
        let raw = self
            .bump()
            .ok_or_else(|| format!("{head} missing argument"))?;
        let arg = strip_quotes(raw);
        let prim = match head {
            "-name" => Prim::Name(arg.to_string()),
            "-path" => Prim::Path(arg.to_string()),
            "-size" => {
                let (cmp, n) = parse_size(arg)?;
                Prim::Size(cmp, n)
            }
            "-newer" => Prim::Newer(arg.to_string()),
            other => return Err(format!("unknown predicate {other}")),
        };
        Ok(Expr::Prim(prim))
    }
}

/// Strip one layer of matching surrounding single/double quotes (the whole `--expr`
/// is one shell arg, so inner quotes are literal; this lets `-name '*.rs'` work).
fn strip_quotes(s: &str) -> &str {
    let b = s.as_bytes();
    if b.len() >= 2 && (b[0] == b'\'' || b[0] == b'"') && b[0] == b[b.len() - 1] {
        &s[1..s.len() - 1]
    } else {
        s
    }
}

/// All `-newer FILE` arguments referenced in `expr` (so the caller can stat each
/// once and cache, rather than per-result).
pub fn newer_files(expr: &Expr) -> Vec<String> {
    let mut out = Vec::new();
    collect_newer(expr, &mut out);
    out
}

fn collect_newer(expr: &Expr, out: &mut Vec<String>) {
    match expr {
        Expr::Prim(Prim::Newer(f)) => out.push(f.clone()),
        Expr::Prim(_) => {}
        Expr::And(a, b) | Expr::Or(a, b) => {
            collect_newer(a, out);
            collect_newer(b, out);
        }
        Expr::Not(e) => collect_newer(e, out),
    }
}

/// A token that can start a factor (for implicit-AND detection).
fn is_factor_start(t: &str) -> bool {
    matches!(t, "(" | "!" | "-not")
        || t.starts_with('-') && !matches!(t, "-a" | "-and" | "-o" | "-or")
}

/// Parse a `-size` argument: `[+|-]N[unit]` where unit ∈ {c, k, M, G} (c = bytes,
/// default). Returns (comparison, byte count).
fn parse_size(s: &str) -> Result<(Cmp, i64), String> {
    let (cmp, rest) = match s.as_bytes().first() {
        Some(b'+') => (Cmp::Gt, &s[1..]),
        Some(b'-') => (Cmp::Lt, &s[1..]),
        _ => (Cmp::Eq, s),
    };
    let (num_part, mult) = match rest.as_bytes().last() {
        Some(b'c') => (&rest[..rest.len() - 1], 1i64),
        Some(b'k') => (&rest[..rest.len() - 1], 1024),
        Some(b'M') => (&rest[..rest.len() - 1], 1024 * 1024),
        Some(b'G') => (&rest[..rest.len() - 1], 1024 * 1024 * 1024),
        _ => (rest, 1),
    };
    let n: i64 = num_part
        .parse()
        .map_err(|_| format!("bad -size number: {s}"))?;
    Ok((cmp, n.checked_mul(mult).unwrap_or(i64::MAX)))
}

// ---------------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------------

/// Evaluate `expr` against `(path, meta)`. `newer_mtime` resolves a `-newer
/// FILE` argument to FILE's mtime (seconds), or `None` if unresolvable (the
/// predicate is then false).
pub fn eval<F>(expr: &Expr, path: &str, meta: &LiteMeta, newer_mtime: &F) -> bool
where
    F: Fn(&str) -> Option<i64>,
{
    match expr {
        Expr::Prim(p) => eval_prim(p, path, meta, newer_mtime),
        Expr::Not(e) => !eval(e, path, meta, newer_mtime),
        Expr::And(a, b) => eval(a, path, meta, newer_mtime) && eval(b, path, meta, newer_mtime),
        Expr::Or(a, b) => eval(a, path, meta, newer_mtime) || eval(b, path, meta, newer_mtime),
    }
}

fn eval_prim<F>(p: &Prim, path: &str, meta: &LiteMeta, newer_mtime: &F) -> bool
where
    F: Fn(&str) -> Option<i64>,
{
    match p {
        Prim::Name(pat) => {
            let bn = Path::new(path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(path);
            glob_matches(pat, bn)
        }
        Prim::Path(pat) => glob_matches(pat, path),
        Prim::Size(cmp, n) => match cmp {
            Cmp::Eq => meta.size == *n,
            Cmp::Gt => meta.size > *n,
            Cmp::Lt => meta.size < *n,
        },
        Prim::Newer(file) => match newer_mtime(file) {
            Some(t) => meta.mtime > t,
            None => false,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(size: i64, mtime: i64) -> LiteMeta {
        LiteMeta {
            is_dir: false,
            size,
            mtime,
        }
    }

    #[test]
    fn parse_name_and_size() {
        let e = parse("-name '*.rs' -size +0c").unwrap();
        assert_eq!(
            e,
            Expr::And(
                Box::new(Expr::Prim(Prim::Name("*.rs".into()))),
                Box::new(Expr::Prim(Prim::Size(Cmp::Gt, 0)))
            )
        );
    }

    #[test]
    fn parse_or_parens_not() {
        let e = parse("( -name a -o -name b ) -a ! -name c").unwrap();
        assert_eq!(
            e,
            Expr::And(
                Box::new(Expr::Or(
                    Box::new(Expr::Prim(Prim::Name("a".into()))),
                    Box::new(Expr::Prim(Prim::Name("b".into())))
                )),
                Box::new(Expr::Not(Box::new(Expr::Prim(Prim::Name("c".into())))))
            )
        );
    }

    #[test]
    fn parse_size_units() {
        assert_eq!(parse_size("+1k").unwrap(), (Cmp::Gt, 1024));
        assert_eq!(parse_size("2M").unwrap(), (Cmp::Eq, 2 * 1024 * 1024));
        assert_eq!(
            parse_size("-3G").unwrap(),
            (Cmp::Lt, 3 * 1024 * 1024 * 1024)
        );
        assert_eq!(parse_size("100").unwrap(), (Cmp::Eq, 100));
    }

    #[test]
    fn eval_name_glob_basename() {
        let e = parse("-name '*.rs'").unwrap();
        assert!(eval(&e, "/x/src/foo.rs", &meta(0, 0), &|_| None));
        assert!(!eval(&e, "/x/src/foo.txt", &meta(0, 0), &|_| None));
    }

    #[test]
    fn eval_path_glob() {
        let e = parse("-path '*src*'").unwrap();
        assert!(eval(&e, "/proj/src/a.rs", &meta(0, 0), &|_| None));
        assert!(!eval(&e, "/proj/docs/a.md", &meta(0, 0), &|_| None));
    }

    #[test]
    fn eval_size_cmp() {
        let m = meta(200, 0);
        assert!(eval(&parse("-size +100c").unwrap(), "/f", &m, &|_| None));
        assert!(eval(&parse("-size -1k").unwrap(), "/f", &m, &|_| None));
        assert!(eval(&parse("-size 200c").unwrap(), "/f", &m, &|_| None));
        assert!(!eval(&parse("-size 100c").unwrap(), "/f", &m, &|_| None));
    }

    #[test]
    fn eval_newer() {
        let e = parse("-newer ref").unwrap();
        // ref mtime = 100; file mtime 150 → newer.
        assert!(eval(&e, "/f", &meta(0, 150), &|f| (f == "ref").then_some(100)));
        // file mtime 50 → not newer.
        assert!(!eval(&e, "/f", &meta(0, 50), &|f| (f == "ref").then_some(100)));
    }

    #[test]
    fn eval_boolean_combo() {
        // rs files over 50 bytes, excluding .md
        let e = parse("-name '*.rs' -size +50c").unwrap();
        assert!(eval(&e, "/a.rs", &meta(100, 0), &|_| None));
        assert!(!eval(&e, "/a.rs", &meta(10, 0), &|_| None));
        assert!(!eval(&e, "/a.txt", &meta(100, 0), &|_| None));
    }

    #[test]
    fn parse_rejects_trailing() {
        assert!(parse("-name a b").is_err()); // 'b' is a trailing bare token
    }
}
