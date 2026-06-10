import Foundation

/// Pinyin index for Chinese filename search.
///
/// Uses CFStringTokenizer for Chinese word segmentation and CFStringTransform
/// to convert to pinyin. Builds two Trie structures:
/// - **fullPinyinTrie**: full pinyin strings (e.g., "baogao") for each Chinese token,
///   plus a concatenated full-pinyin string for the entire filename
/// - **firstLetterTrie**: concatenated first-letter abbreviation (e.g., "jdbg")
///   across all tokens in a filename
///
/// All input is NFC-normalized before processing. Non-Chinese tokens are skipped.
///
/// Thread safety: This is a value type (struct). When used inside an actor
/// (e.g. `InMemoryIndex`), no internal synchronization is needed.
struct PinyinIndex {

    /// Maps a trie key (as scalar array) to the set of FileRecord IDs stored at that key.
    /// Needed because Trie stores a single value per key — we use a Set to hold multiple IDs.
    private var fullPinyinEntries: [[UnicodeScalar]: Set<UInt32>] = [:]
    private var firstLetterEntries: [[UnicodeScalar]: Set<UInt32>] = [:]

    /// Trie for full pinyin prefix lookup. Values are sets of FileRecord IDs.
    /// The entries dict is the source of truth; the trie mirrors it for prefix enumeration.
    private var fullPinyinTrie = Trie<UnicodeScalar, Set<UInt32>>()

    /// Trie for first-letter abbreviation prefix lookup. Values are sets of FileRecord IDs.
    private var firstLetterTrie = Trie<UnicodeScalar, Set<UInt32>>()

    /// Tracks which FileRecord IDs have Chinese content (for count).
    private var chineseIDs: Set<UInt32> = []

    /// Number of entries with Chinese characters.
    var count: Int { chineseIDs.count }

    /// Whether the index is empty.
    var isEmpty: Bool { chineseIDs.isEmpty }

    // MARK: - Insert

    /// Insert a filename, extracting pinyin from Chinese tokens and indexing them.
    /// Non-Chinese tokens are silently skipped.
    mutating func insert(name: String, id: UInt32) {
        let normalized = name.precomposedStringWithCanonicalMapping
        let tokens = tokenizeToPinyin(normalized)

        guard !tokens.isEmpty else { return }

        chineseIDs.insert(id)

        var allFirstLetters: [UnicodeScalar] = []
        var allFullPinyin: [UnicodeScalar] = []

        for (fullPinyin, firstLetters) in tokens {
            // Insert each token's full pinyin into trie
            let fullScalars = Array(fullPinyin.unicodeScalars)
            if !fullScalars.isEmpty {
                fullPinyinEntries[fullScalars, default: []].insert(id)
                fullPinyinTrie.insert(fullScalars, value: fullPinyinEntries[fullScalars]!)
            }

            allFirstLetters.append(contentsOf: firstLetters)
            allFullPinyin.append(contentsOf: fullScalars)
        }

        // Insert suffixes of the concatenated full-pinyin starting at each token boundary.
        // This allows prefix-matching from any token start, e.g.:
        // "季度報告" -> tokens "jidu","bao","gao" -> concatenated "jidubaogao"
        // Suffixes: "jidubaogao", "baogao", "gao"
        // So searching "baogao" (prefix of "baogao" suffix) finds a match.
        if !allFullPinyin.isEmpty {
            // offset tracks position in allFullPinyin as we walk through tokens
            var offset = 0
            for (fullPinyin, _) in tokens {
                let tokenScalars = Array(fullPinyin.unicodeScalars)
                // Insert the suffix starting at this token
                let suffix = Array(allFullPinyin[offset...])
                if !suffix.isEmpty {
                    fullPinyinEntries[suffix, default: []].insert(id)
                    fullPinyinTrie.insert(suffix, value: fullPinyinEntries[suffix]!)
                }
                offset += tokenScalars.count
            }
        }

        // Insert concatenated first-letter abbreviation into trie
        if !allFirstLetters.isEmpty {
            firstLetterEntries[allFirstLetters, default: []].insert(id)
            firstLetterTrie.insert(allFirstLetters, value: firstLetterEntries[allFirstLetters]!)
        }
    }

    // MARK: - Search

    /// Search for file IDs matching the given pinyin query.
    /// Searches both the full pinyin trie and the first-letter trie,
    /// returning the union of results.
    func search(pinyin: String) -> [UInt32] {
        let normalized = pinyin.precomposedStringWithCanonicalMapping.lowercased()
        let scalars = Array(normalized.unicodeScalars)
        guard !scalars.isEmpty else { return Array(chineseIDs) }

        // Search full pinyin trie — results come back with Set<UInt32> values
        let fullResults = fullPinyinTrie.search(prefix: scalars)
        let flResults = firstLetterTrie.search(prefix: scalars)

        // Merge all sets and deduplicate
        var seen = Set<UInt32>()
        for set in fullResults {
            seen.formUnion(set)
        }
        for set in flResults {
            seen.formUnion(set)
        }
        return Array(seen)
    }

    // MARK: - Remove

    /// Remove a filename's pinyin entries from the index.
    /// No-op if the id was never inserted or had no Chinese content.
    mutating func remove(name: String, id: UInt32) {
        guard chineseIDs.remove(id) != nil else { return }

        let normalized = name.precomposedStringWithCanonicalMapping
        let tokens = tokenizeToPinyin(normalized)

        // Collect all keys to remove before mutating, to avoid exclusivity issues
        var fullPinyinKeys: [[UnicodeScalar]] = []
        var allFirstLetters: [UnicodeScalar] = []

        for (fullPinyin, firstLetters) in tokens {
            let fullScalars = Array(fullPinyin.unicodeScalars)
            if !fullScalars.isEmpty {
                fullPinyinKeys.append(fullScalars)
            }
            allFirstLetters.append(contentsOf: firstLetters)
        }

        // Build the concatenated full-pinyin key
        var allFullPinyin: [UnicodeScalar] = []
        for key in fullPinyinKeys {
            allFullPinyin.append(contentsOf: key)
        }
        // Also insert suffixes starting at each token boundary (mirror insert logic)
        if !allFullPinyin.isEmpty {
            var offset = 0
            for key in fullPinyinKeys {
                let suffix = Array(allFullPinyin[offset...])
                if !suffix.isEmpty {
                    fullPinyinKeys.append(suffix)
                }
                offset += key.count
            }
        }

        // Remove from full pinyin entries and trie
        for key in fullPinyinKeys {
            if var set = fullPinyinEntries[key] {
                set.remove(id)
                if set.isEmpty {
                    fullPinyinEntries.removeValue(forKey: key)
                    fullPinyinTrie.remove(key)
                } else {
                    fullPinyinEntries[key] = set
                    fullPinyinTrie.insert(key, value: set)
                }
            }
        }

        // Remove from first-letter entries and trie
        if !allFirstLetters.isEmpty {
            if var set = firstLetterEntries[allFirstLetters] {
                set.remove(id)
                if set.isEmpty {
                    firstLetterEntries.removeValue(forKey: allFirstLetters)
                    firstLetterTrie.remove(allFirstLetters)
                } else {
                    firstLetterEntries[allFirstLetters] = set
                    firstLetterTrie.insert(allFirstLetters, value: set)
                }
            }
        }
    }

    /// Tokenize a string into pinyin representations using CFStringTokenizer.
    /// Returns an array of (fullPinyin, firstLetterScalars) tuples for each Chinese token.
    /// Non-Chinese tokens are skipped.
    private func tokenizeToPinyin(_ input: String) -> [(fullPinyin: String, firstLetters: [UnicodeScalar])] {
        let cfStr = input as CFString
        let locale = CFLocaleCopyCurrent()

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfStr,
            CFRangeMake(0, CFStringGetLength(cfStr)),
            CFOptionFlags(kCFStringTokenizerUnitWord),
            locale
        )

        var results: [(fullPinyin: String, firstLetters: [UnicodeScalar])] = []

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (input as NSString).substring(with: NSRange(
                location: range.location, length: range.length))

            // Only process tokens containing Chinese characters
            if tokenContainsChinese(token) {
                let pinyin = tokenToPinyin(token)
                if !pinyin.fullPinyin.isEmpty {
                    results.append(pinyin)
                }
            }

            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return results
    }

    /// Convert a Chinese token to pinyin using CFStringTransform.
    /// Returns (full pinyin without spaces/tone marks, first-letter scalars).
    private func tokenToPinyin(_ token: String) -> (fullPinyin: String, firstLetters: [UnicodeScalar]) {
        let mutable = NSMutableString(string: token)

        // Step 1: Transform to Latin (pinyin with tone marks)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)

        // Step 2: Strip diacritics (tone marks)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        // Step 3: Lowercase
        let pinyin = (mutable as String).lowercased()

        // Step 4: Split by spaces to get individual syllables, then join without spaces
        let syllables = pinyin.split(separator: " ")
        let fullPinyin = syllables.joined()

        // Step 5: Extract first letter of each syllable
        let firstLetters = syllables.compactMap { syllable -> UnicodeScalar? in
            syllable.unicodeScalars.first
        }

        return (fullPinyin, firstLetters)
    }

    /// Check if a string contains any CJK Unified Ideographs.
    private func tokenContainsChinese(_ s: String) -> Bool {
        Self.containsChinese(s)
    }

    // MARK: - Public Helpers

    /// A tokenized Chinese segment with its pinyin representation and position in the source string.
    struct PinyinToken {
        /// Full pinyin (no spaces/tone marks), e.g. "baogao"
        public let fullPinyin: String
        /// First-letter scalars, e.g. ["b", "g"]
        public let firstLetters: [UnicodeScalar]
        /// Range of the original CJK characters in the source string
        public let range: Range<String.Index>
    }

    /// Tokenize a string into pinyin representations with character ranges.
    /// Returns one `PinyinToken` per Chinese segment found by the tokenizer.
    /// Non-Chinese tokens are skipped. Useful for highlighting CJK characters
    /// that matched a pinyin query.
    public static func tokenizeWithRanges(_ input: String) -> [PinyinToken] {
        let cfStr = input as CFString
        let locale = CFLocaleCopyCurrent()

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfStr,
            CFRangeMake(0, CFStringGetLength(cfStr)),
            CFOptionFlags(kCFStringTokenizerUnitWord),
            locale
        )

        var results: [PinyinToken] = []

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
            let token = (input as NSString).substring(with: nsRange)

            if containsChinese(token) {
                let pinyin = tokenToPinyinStatic(token)
                if !pinyin.fullPinyin.isEmpty,
                   let range = Range(nsRange, in: input) {
                    results.append(PinyinToken(
                        fullPinyin: pinyin.fullPinyin,
                        firstLetters: pinyin.firstLetters,
                        range: range
                    ))
                }
            }

            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }

        return results
    }

    /// Returns character ranges in `text` whose pinyin representation matches `query`.
    /// Tries both first-letter abbreviation and full pinyin matching.
    /// Returns an empty array if no pinyin match is found.
    public static func matchRanges(in text: String, query: String) -> [Range<String.Index>] {
        let tokens = tokenizeWithRanges(text)
        guard !tokens.isEmpty else { return [] }

        let queryLower = query.lowercased()

        // Build concatenated first-letter string across all tokens
        let allFirstLetters = tokens.flatMap(\.firstLetters)
        let firstLetterStr = String(String.UnicodeScalarView(allFirstLetters)).lowercased()

        // Build concatenated full-pinyin string, tracking which token owns each character offset
        var allFullPinyin = ""
        var tokenOffsets: [(token: PinyinToken, pinyinOffset: Int)] = []
        for token in tokens {
            tokenOffsets.append((token, allFullPinyin.count))
            allFullPinyin += token.fullPinyin.lowercased()
        }

        var matchedRanges: [Range<String.Index>] = []

        // Try first-letter abbreviation match
        if firstLetterStr.hasPrefix(queryLower) {
            // Count how many first-letter characters the query consumes
            var charCount = 0
            for token in tokens {
                charCount += token.firstLetters.count
                if charCount >= queryLower.count {
                    // Highlight from first token start through this token's end
                    let end = token.range.upperBound
                    matchedRanges.append(tokens[0].range.lowerBound..<end)
                    break
                }
            }
            if !matchedRanges.isEmpty { return matchedRanges }
        }

        // Try full pinyin prefix match per token
        for (token, _) in tokenOffsets {
            if token.fullPinyin.lowercased().hasPrefix(queryLower) {
                matchedRanges.append(token.range)
            }
        }
        if !matchedRanges.isEmpty { return matchedRanges }

        // Try full pinyin prefix match on concatenated string (cross-token)
        if allFullPinyin.hasPrefix(queryLower) {
            // Find how far into the concatenated pinyin the query spans
            var consumed = queryLower.count
            var startToken = tokens[0]
            var endBound = tokens[0].range.upperBound
            for (token, offset) in tokenOffsets {
                if offset < queryLower.count {
                    endBound = token.range.upperBound
                }
            }
            matchedRanges.append(startToken.range.lowerBound..<endBound)
        }

        return matchedRanges
    }

    // MARK: - Private Static Helpers

    /// Check if a string contains any CJK Unified Ideographs.
    private static func containsChinese(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0xF900...0xFAFF).contains(v)
                || (0x20000...0x2A6DF).contains(v)
        }
    }

    /// Static version of tokenToPinyin for use without an instance.
    private static func tokenToPinyinStatic(_ token: String) -> (fullPinyin: String, firstLetters: [UnicodeScalar]) {
        let mutable = NSMutableString(string: token)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let pinyin = (mutable as String).lowercased()
        let syllables = pinyin.split(separator: " ")
        let fullPinyin = syllables.joined()
        let firstLetters = syllables.compactMap { $0.unicodeScalars.first }
        return (fullPinyin, firstLetters)
    }
}
