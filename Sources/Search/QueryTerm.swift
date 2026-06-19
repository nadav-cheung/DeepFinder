// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex

// MARK: - QueryTerm

/// A node in the parsed query abstract syntax tree (AST).
///
/// Produced by ``QueryParser/parse(_:)`` from a raw query string. The AST supports
/// boolean operators, wildcards, regex, modifiers, and path qualifiers.
///
/// ## Grammar (informal)
/// ```
/// query      -> expr*
/// expr       -> or_expr (SPACE or_expr)*
/// or_expr    -> primary ('|' primary)*
/// primary    -> '!' primary | '(' query ')' | atom
/// atom       -> modifier | regex_literal | wildcard | path_qualifier | text
/// ```
///
/// Default behavior: space-separated terms are ANDed. `|` produces OR.
/// `!` prefix negates. Parentheses group sub-expressions.
public indirect enum QueryTerm: Equatable, Sendable {
    /// Plain text search term (case-insensitive substring match).
    case text(String)
    /// Logical AND of sub-terms (implicit for space-separated terms).
    case and([QueryTerm])
    /// Logical OR of sub-terms (explicit `|` operator).
    case or([QueryTerm])
    /// Logical negation of a sub-term (`!` prefix).
    case not(QueryTerm)
    /// Glob-style wildcard pattern (supports `*` and `?`).
    case wildcard(String)
    /// Regular expression pattern (prefixed with `regex:`).
    case regex(String)
    /// Key-value modifier (e.g. `ext:pdf`, `size:>10mb`, `dm:today`).
    case modifier(key: String, value: String)
    /// Path qualifier — restricts results to paths containing this component
    /// (expressed with backslash-space: `Projects\ report`).
    case pathQualifier(String)

    /// Recursively check whether this term or any nested term contains `.or` or `.not`.
    /// Used by ``ParsedQuery/hasBooleanOperators`` to decide between the fast
    /// textOnlyQuery path and the full AST evaluation path.
    fileprivate var hasOrOrNot: Bool {
        switch self {
        case .or, .not: return true
        case .and(let sub):
            return sub.contains { $0.hasOrOrNot }
        case .text, .wildcard, .regex, .modifier, .pathQualifier:
            return false
        }
    }
}

// MARK: - ParsedQuery

/// The result of parsing a user query string.
public struct ParsedQuery: Equatable, Sendable {
    /// Parsed query terms forming an AST.
    public var terms: [QueryTerm]
    /// Original user input, unmodified.
    public var rawQuery: String
}

// MARK: - ParsedQuery Modifier Extraction

extension ParsedQuery {

    /// All modifier key-value pairs extracted from the parsed AST.
    ///
    /// Walks the term tree recursively; only ``QueryTerm/modifier(key:value:)``
    /// nodes are collected. Nested modifiers inside `and`/`or`/`not` groups
    /// are also extracted so that `(report | memo) size:>10mb` works as expected.
    public var modifierPairs: [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        collectModifiers(terms, into: &pairs)
        return pairs
    }

    /// Rebuild the query string with all modifier terms removed.
    ///
    /// The returned string is suitable for passing to text-based search providers.
    /// Modifiers are stripped; text, wildcard, regex, and path-qualifier terms
    /// are preserved. Boolean structure (and/or/not) is flattened into a
    /// space-joined string for maximal search recall.
    public var textOnlyQuery: String {
        rebuildWithoutModifiers(terms)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether the parsed AST contains any boolean operators (OR or NOT).
    /// `true` means the query needs AST evaluation; `false` means the flat
    /// textOnlyQuery path is sufficient.
    public var hasBooleanOperators: Bool {
        terms.contains { $0.hasOrOrNot }
    }

    // MARK: - Private helpers

    private func collectModifiers(
        _ terms: [QueryTerm],
        into pairs: inout [(key: String, value: String)]
    ) {
        for term in terms {
            switch term {
            case .modifier(let key, let value):
                pairs.append((key, value))
            case .and(let sub), .or(let sub):
                collectModifiers(sub, into: &pairs)
            case .not(let sub):
                collectModifiers([sub], into: &pairs)
            case .text, .wildcard, .regex, .pathQualifier:
                break
            }
        }
    }

    private func rebuildWithoutModifiers(_ terms: [QueryTerm]) -> String {
        terms.compactMap { term -> String? in
            switch term {
            case .text(let s):
                return s
            case .wildcard(let s):
                return s
            case .regex(let s):
                return "regex:\(s)"
            case .modifier:
                return nil
            case .pathQualifier(let s):
                return "\(s)\\ "
            case .and(let sub):
                return rebuildWithoutModifiers(sub)
            case .or(let sub):
                let kept = sub.filter { if case .modifier = $0 { false } else { true } }
                guard !kept.isEmpty else { return nil }
                return kept.map { rebuildWithoutModifiers([$0]) }.joined(separator: "|")
            case .not(let sub):
                if case .modifier = sub { return nil }
                let inner = rebuildWithoutModifiers([sub])
                return inner.isEmpty ? nil : "!\(inner)"
            }
        }.joined(separator: " ")
    }
}

// MARK: - QueryParser

/// Parses a raw query string into a structured `ParsedQuery` AST.
///
/// Grammar (informal):
///   query      → expr*
///   expr       → or_expr (SPACE or_expr)*
///   or_expr    → primary ('|' primary)*
///   primary    → '!' primary | '(' query ')' | atom
///   atom       → modifier | regex_literal | wildcard | path_qualifier | text
///
/// Default behavior: space-separated terms are ANDed. `|` produces OR.
/// `!` prefix negates. Parentheses group sub-expressions.
/// No cases exist — this enum is used only as a namespace for static methods.
public enum QueryParser {

    /// Parse a raw query string into a structured `ParsedQuery` AST.
    ///
    /// - Parameter input: The raw query string typed by the user.
    /// - Returns: A `ParsedQuery` with the parsed AST and original query.
    public static func parse(_ input: String) -> ParsedQuery {
        let tokens = tokenize(input)
        var parser = _Parser(tokens: tokens)
        var terms = parser.parseQuery()
        // Multiple top-level terms are implicitly ANDed.
        if terms.count > 1 {
            terms = [.and(terms)]
        }
        return ParsedQuery(terms: terms, rawQuery: input)
    }
}

// MARK: - Tokenizer

extension QueryParser {

    /// Recognized modifier key prefixes.
    /// Must include every key that ``FilterPipeline/parse(from:)`` handles.
    private static let modifierKeys: Set<String> = [
        "case", "file", "folder", "ext", "path",
        "size", "dm", "dc", "depth", "len", "width", "height",
        "duration", "pages", "pagecount", "fps", "bitrate",
        "artist", "album", "title", "genre", "codec",
        "audio", "video", "pic", "doc"
    ]

    /// Tokenize raw input into a flat list of tokens.
    ///
    /// Rules:
    /// - Backslash-space (`\<space>`): marks preceding word as a path qualifier,
    ///   consumes both backslash and space. The space also acts as an AND separator.
    /// - Backslash-non-space: escapes the next character literally into the current word.
    /// - `|` (unescaped): OR operator.
    /// - `!`: NOT operator.
    /// - `(`, `)`: grouping.
    /// - Whitespace: AND separator (implicit).
    /// - `regex:` prefix: rest of that word is a regex pattern.
    /// - `key:value` with known key: modifier token.
    /// - `*` or `?` in word: wildcard pattern.
    /// - Everything else: plain text.
    private static func tokenize(_ input: String) -> [_Token] {
        var tokens: [_Token] = []
        let chars = Array(input)
        var pos = 0
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(classifyWord(word))
            word = ""
        }

        while pos < chars.count {
            let char = chars[pos]

            switch char {
            case " ", "\t":
                // Whitespace: flush current word; AND is implicit between tokens.
                flushWord()
                pos += 1

            case "(":
                flushWord()
                tokens.append(.lparen)
                pos += 1

            case ")":
                flushWord()
                tokens.append(.rparen)
                pos += 1

            case "|":
                flushWord()
                tokens.append(.or)
                pos += 1

            case "!":
                flushWord()
                tokens.append(.not)
                pos += 1

            case "\\":
                let nextPos = pos + 1
                guard nextPos < chars.count else {
                    // Trailing backslash: treat as literal.
                    word.append("\\")
                    pos += 1
                    break
                }
                let nextChar = chars[nextPos]

                if nextChar == " " {
                    // Backslash-space: current word is a path qualifier.
                    // Consume backslash and space; space also acts as separator.
                    if word.isEmpty {
                        pos = nextPos + 1
                    } else {
                        tokens.append(.pathQualifier(word))
                        word = ""
                        pos = nextPos + 1
                    }
                } else if nextChar == "|" || nextChar == "(" || nextChar == ")" || nextChar == "!" || nextChar == "\\" {
                    // Escape a special character: append literally to current word.
                    word.append(nextChar)
                    pos = nextPos + 1
                } else {
                    // Not escaping a special char: treat backslash as literal.
                    word.append("\\")
                    pos += 1
                }

            default:
                word.append(char)
                pos += 1
            }
        }

        flushWord()
        return tokens
    }

    /// Classify a raw word into the appropriate token type.
    private static func classifyWord(_ word: String) -> _Token {
        // regex: prefix → extract the pattern after the prefix
        if word.hasPrefix("regex:") {
            let pattern = String(word.dropFirst(6))
            return .regex(pattern)
        }

        // key:value with a known modifier key
        if let colonIndex = word.firstIndex(of: ":") {
            let key = String(word[..<colonIndex])
            let value = String(word[word.index(after: colonIndex)...])
            if modifierKeys.contains(key) && !value.isEmpty {
                return .modifier(key: key, value: value)
            }
        }

        // Contains wildcard characters
        if word.contains("*") || word.contains("?") {
            return .wildcard(word)
        }

        // Default: plain text
        return .text(word)
    }
}

// MARK: - Internal Token Type

/// Internal token type used during parsing. Not exported.
private enum _Token: Equatable {
    case text(String)
    case or
    case not
    case wildcard(String)
    case regex(String)
    case modifier(key: String, value: String)
    case pathQualifier(String)
    case lparen
    case rparen
}

// MARK: - Recursive Descent Parser

private struct _Parser {
    private let tokens: [_Token]
    private var index: Int = 0

    public init(tokens: [_Token]) {
        self.tokens = tokens
    }

    private var current: _Token? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func advance() -> _Token? {
        defer { index += 1 }
        return current
    }

    // MARK: Grammar Rules

    /// query → term*
    /// Top-level terms are implicitly ANDed when there are multiple.
    mutating func parseQuery() -> [QueryTerm] {
        var terms: [QueryTerm] = []

        while let token = current {
            if case .rparen = token { break }
            let term = parseOrExpr()
            terms.append(term)
        }

        return terms
    }

    /// or_expr → primary ('|' primary)*
    private mutating func parseOrExpr() -> QueryTerm {
        var terms: [QueryTerm] = [parsePrimary()]

        while case .or = current {
            _ = advance() // consume '|'
            terms.append(parsePrimary())
        }

        return terms.count == 1 ? terms[0] : .or(terms)
    }

    /// primary → '!' primary | '(' query ')' | atom
    private mutating func parsePrimary() -> QueryTerm {
        guard let token = current else {
            return .text("")
        }

        switch token {
        case .not:
            _ = advance()
            return .not(parsePrimary())

        case .lparen:
            _ = advance() // consume '('
            let inner = parseQuery()
            _ = advance() // consume ')'
            switch inner.count {
            case 0:  return .text("")
            case 1:  return inner[0]
            default: return .and(inner)
            }

        case .text(let s):
            _ = advance()
            return .text(s)

        case .wildcard(let s):
            _ = advance()
            return .wildcard(s)

        case .regex(let s):
            _ = advance()
            return .regex(s)

        case .modifier(let k, let v):
            _ = advance()
            return .modifier(key: k, value: v)

        case .pathQualifier(let s):
            _ = advance()
            return .pathQualifier(s)

        case .or:
            _ = advance()
            return .text("|")

        case .rparen:
            _ = advance()
            return .text(")")
        }
    }
}
