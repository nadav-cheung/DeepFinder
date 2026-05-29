import Foundation

// MARK: - QueryTerm

/// A node in the parsed query AST.
indirect enum QueryTerm: Equatable, Sendable {
    case text(String)
    case and([QueryTerm])
    case or([QueryTerm])
    case not(QueryTerm)
    case wildcard(String)
    case regex(String)
    case modifier(key: String, value: String)
    case pathQualifier(String)
}

// MARK: - ParsedQuery

/// The result of parsing a user query string.
struct ParsedQuery: Equatable, Sendable {
    /// Parsed query terms forming an AST.
    var terms: [QueryTerm]
    /// Original user input, unmodified.
    var rawQuery: String
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
enum QueryParser {

    static func parse(_ input: String) -> ParsedQuery {
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
    private static let modifierKeys: Set<String> = [
        "case", "file", "folder", "ext", "path"
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

    init(tokens: [_Token]) {
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
            advance() // consume '|'
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
            advance()
            return .not(parsePrimary())

        case .lparen:
            advance() // consume '('
            let inner = parseQuery()
            _ = advance() // consume ')'
            switch inner.count {
            case 0:  return .text("")
            case 1:  return inner[0]
            default: return .and(inner)
            }

        case .text(let s):
            advance()
            return .text(s)

        case .wildcard(let s):
            advance()
            return .wildcard(s)

        case .regex(let s):
            advance()
            return .regex(s)

        case .modifier(let k, let v):
            advance()
            return .modifier(key: k, value: v)

        case .pathQualifier(let s):
            advance()
            return .pathQualifier(s)

        case .or:
            advance()
            return .text("|")

        case .rparen:
            advance()
            return .text(")")
        }
    }
}
