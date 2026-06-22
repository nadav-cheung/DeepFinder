// SPDX-License-Identifier: MIT
//! Boolean query: `AND` / `OR` / `NOT` + parentheses (Zoekt-style), ported from
//! the Swift `ParsedQuery` / `searchWithBooleanAST`. Uppercase `AND`/`OR`/`NOT`
//! are operators; bare adjacent terms are implicitly ANDed. A lone term takes
//! the fast single-term path in [`crate::query`]; anything with operators is
//! evaluated here by combining per-term DocID sets.

use std::collections::BTreeSet;

use crate::{trigram::trigrams, DbReader, DbSource, Result};

#[derive(Debug, Clone)]
pub enum Node {
    Term(String),
    And(Box<Node>, Box<Node>),
    Or(Box<Node>, Box<Node>),
    Not(Box<Node>),
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Word(String),
    And,
    Or,
    Not,
    LParen,
    RParen,
}

fn tokenize(s: &str) -> Vec<Tok> {
    let mut toks = Vec::new();
    let mut cur = String::new();
    let flush = |cur: &mut String, toks: &mut Vec<Tok>| {
        if !cur.is_empty() {
            let w = std::mem::take(cur);
            match w.as_str() {
                "AND" => toks.push(Tok::And),
                "OR" => toks.push(Tok::Or),
                "NOT" => toks.push(Tok::Not),
                _ => toks.push(Tok::Word(w)),
            }
        }
    };
    for c in s.chars() {
        match c {
            '(' => {
                flush(&mut cur, &mut toks);
                toks.push(Tok::LParen);
            }
            ')' => {
                flush(&mut cur, &mut toks);
                toks.push(Tok::RParen);
            }
            ws if ws.is_whitespace() => flush(&mut cur, &mut toks),
            _ => cur.push(c),
        }
    }
    flush(&mut cur, &mut toks);
    toks
}

// ---------------------------------------------------------------------------
// Parser (precedence: NOT > AND > OR; implicit AND between adjacent factors)
// ---------------------------------------------------------------------------

pub fn parse(s: &str) -> Option<Node> {
    let mut p = Parser {
        toks: tokenize(s),
        pos: 0,
    };
    let node = p.parse_or()?;
    if p.pos != p.toks.len() {
        return None; // trailing tokens → malformed
    }
    Some(node)
}

struct Parser {
    toks: Vec<Tok>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }
    fn bump(&mut self) -> Option<Tok> {
        let t = self.toks.get(self.pos).cloned();
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn parse_or(&mut self) -> Option<Node> {
        let mut left = self.parse_and()?;
        while matches!(self.peek(), Some(Tok::Or)) {
            self.bump();
            let right = self.parse_and()?;
            left = Node::Or(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn parse_and(&mut self) -> Option<Node> {
        let mut left = self.parse_factor()?;
        loop {
            match self.peek() {
                Some(Tok::And) => {
                    self.bump();
                }
                // implicit AND: another factor starts here
                Some(Tok::Word(_)) | Some(Tok::Not) | Some(Tok::LParen) => {}
                _ => break,
            }
            let right = self.parse_factor()?;
            left = Node::And(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn parse_factor(&mut self) -> Option<Node> {
        match self.bump()? {
            Tok::Not => {
                let f = self.parse_factor()?;
                Some(Node::Not(Box::new(f)))
            }
            Tok::LParen => {
                let e = self.parse_or()?;
                if !matches!(self.bump(), Some(Tok::RParen)) {
                    return None;
                }
                Some(e)
            }
            Tok::Word(w) => Some(Node::Term(w)),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------------

/// DocID set for a single term (rarest-trigram + substring verify, or linear
/// scan for <3-byte terms).
fn term_docids<S: DbSource>(db: &DbReader<S>, term: &str) -> Result<BTreeSet<u32>> {
    let lower = term.to_lowercase();
    let mut set = BTreeSet::new();
    if lower.is_empty() {
        return Ok(set);
    }
    if lower.len() < 3 {
        for d in 0..db.num_docs() {
            if db.doc_path(d)?.to_lowercase().contains(lower.as_str()) {
                set.insert(d);
            }
        }
        return Ok(set);
    }
    let qtris = trigrams(lower.as_bytes());
    let mut best: Option<Vec<u32>> = None;
    for t in &qtris {
        match db.posting(*t)? {
            Some(post) => {
                best = Some(match best {
                    None => post,
                    Some(b) if post.len() < b.len() => post,
                    Some(b) => b,
                });
            }
            None => return Ok(set),
        }
    }
    let Some(cands) = best else {
        return Ok(set);
    };
    for d in cands {
        if db.doc_path(d)?.to_lowercase().contains(lower.as_str()) {
            set.insert(d);
        }
    }
    Ok(set)
}

fn evaluate<S: DbSource>(db: &DbReader<S>, node: &Node) -> Result<BTreeSet<u32>> {
    match node {
        Node::Term(t) => term_docids(db, t),
        Node::Not(inner) => {
            let excl = evaluate(db, inner)?;
            // complement against all DocIDs (note: O(num_docs); scalability TODO)
            let mut all: BTreeSet<u32> = (0..db.num_docs()).collect();
            all.retain(|d| !excl.contains(d));
            Ok(all)
        }
        Node::And(a, b) => {
            let sa = evaluate(db, a)?;
            let sb = evaluate(db, b)?;
            Ok(sa.intersection(&sb).copied().collect())
        }
        Node::Or(a, b) => {
            let sa = evaluate(db, a)?;
            let sb = evaluate(db, b)?;
            Ok(sa.union(&sb).copied().collect())
        }
    }
}

/// Evaluate a boolean AST and return matching paths (DocID order), capped.
pub fn boolean_query<S: DbSource>(
    db: &DbReader<S>,
    parsed: &Node,
    limit: Option<u32>,
) -> Result<Vec<String>> {
    let docids = evaluate(db, parsed)?;
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let mut out = Vec::new();
    for d in docids {
        out.push(db.doc_path(d)?);
        if out.len() >= cap {
            break;
        }
    }
    Ok(out)
}
