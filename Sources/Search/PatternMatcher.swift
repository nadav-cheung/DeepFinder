import Foundation

/// Performs wildcard and regex pattern matching against file names.
/// Both matchers are case-insensitive and operate on the filename (not the full path).
struct PatternMatcher: Sendable {

    /// Prevent instantiation — all API is static.
    private init() {}

    /// Match `input` against a glob-style wildcard `pattern`.
    ///
    /// - `*` matches any sequence of characters (including empty).
    /// - `?` matches exactly one character.
    /// Matching is case-insensitive.
    ///
    /// Uses a two-pointer backtracking algorithm with O(m*n) worst case
    /// where m = pattern length, n = input length.
    static func matchWildcard(pattern: String, input: String) -> Bool {
        let loweredPattern = pattern.precomposedStringWithCanonicalMapping.lowercased()
        let loweredInput = input.precomposedStringWithCanonicalMapping.lowercased()

        var patternIdx = loweredPattern.startIndex
        var inputIdx = loweredInput.startIndex

        // Backtracking state: position after last '*' in pattern, and
        // the input position at that time.
        var starPatternIdx: String.Index? = nil
        var starInputIdx: String.Index = loweredInput.startIndex

        while inputIdx < loweredInput.endIndex {
            let patternChar = patternIdx < loweredPattern.endIndex
                ? loweredPattern[patternIdx]
                : nil

            if patternChar == "*" {
                // Record backtracking position and advance pattern past '*'.
                starPatternIdx = loweredPattern.index(after: patternIdx)
                starInputIdx = inputIdx
                patternIdx = loweredPattern.index(after: patternIdx)
            } else if patternChar == loweredInput[inputIdx] || patternChar == "?" {
                // Characters match (or '?' wildcard). Advance both.
                patternIdx = loweredPattern.index(after: patternIdx)
                inputIdx = loweredInput.index(after: inputIdx)
            } else if let star = starPatternIdx {
                // Mismatch but we have a previous '*' — backtrack:
                // consume one more input character under the '*'.
                patternIdx = star
                starInputIdx = loweredInput.index(after: starInputIdx)
                inputIdx = starInputIdx
            } else {
                return false
            }
        }

        // Input exhausted. Remaining pattern chars must all be '*'.
        while patternIdx < loweredPattern.endIndex && loweredPattern[patternIdx] == "*" {
            patternIdx = loweredPattern.index(after: patternIdx)
        }

        return patternIdx == loweredPattern.endIndex
    }

    /// Match `input` against a regular expression `pattern`.
    ///
    /// Uses `NSRegularExpression` with `.caseInsensitive` and `.anchorsMatchLines`
    /// options. The pattern is applied to the full input string.
    /// Returns `false` (never throws/crashes) for invalid regex patterns.
    static func matchRegex(pattern: String, input: String) -> Bool {
        // Prevent ReDoS: reject excessively long patterns before compiling.
        guard pattern.count <= 256 else { return false }

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else {
            return false
        }

        let fullRange = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, options: [], range: fullRange) != nil
    }
}
