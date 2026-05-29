import Testing
@testable import DeepFinder

@Suite("FuzzyCorrector")
struct FuzzyCorrectionTests {

    // MARK: - 1. Exact match returns nil (no correction needed)

    @Test("Exact match returns nil")
    func testExactMatchReturnsNil() {
        let corrector = FuzzyCorrector(knownTerms: ["report", "invoice", "photo"])
        let suggestion = corrector.suggest(for: "report")
        #expect(suggestion == nil)
    }

    // MARK: - 2. Typo "repotr" suggests "report"

    @Test("Typo 'repotr' suggests 'report'")
    func testTypoSuggestsCorrection() {
        let corrector = FuzzyCorrector(knownTerms: ["report", "invoice", "photo"])
        let suggestion = corrector.suggest(for: "repotr")
        #expect(suggestion == "report")
    }

    // MARK: - 3. Distance > maxDistance returns nil

    @Test("Distance beyond maxDistance returns nil")
    func testDistanceBeyondMaxReturnsNil() {
        let corrector = FuzzyCorrector(knownTerms: ["report", "invoice", "photo"])
        // "abcdef" is distance 6 from "report" — way beyond maxDistance of 2
        let suggestion = corrector.suggest(for: "abcdef")
        #expect(suggestion == nil)
    }

    // MARK: - 4. Multiple candidates returns shortest distance

    @Test("Multiple candidates returns closest match")
    func testMultipleCandidatesReturnsClosest() {
        let corrector = FuzzyCorrector(knownTerms: ["cat", "car", "bar"])
        // "cap" is distance 1 from "cat", distance 1 from "car", distance 2 from "bar"
        // Both "cat" and "car" are distance 1 — pick the first encountered
        let suggestion = corrector.suggest(for: "cap")
        #expect(suggestion == "cat" || suggestion == "car")
    }

    // MARK: - 5. Empty query returns nil

    @Test("Empty query returns nil")
    func testEmptyQueryReturnsNil() {
        let corrector = FuzzyCorrector(knownTerms: ["report", "invoice"])
        let suggestion = corrector.suggest(for: "")
        #expect(suggestion == nil)
    }

    // MARK: - 6. Single character edit distance works

    @Test("Single character insertion detected")
    func testSingleCharacterEdit() {
        let corrector = FuzzyCorrector(knownTerms: ["abc"])
        // "abx" is distance 1 from "abc" (substitution)
        let suggestion = corrector.suggest(for: "abx")
        #expect(suggestion == "abc")
    }

    // MARK: - 7. Transposition (teh -> the) detected

    @Test("Transposition 'teh' suggests 'the' over farther candidates")
    func testTranspositionDetected() {
        // "teh" is distance 2 from "the" (standard Levenshtein: 2 single-char edits)
        // "watermelon" is distance 9 — clearly out of range
        let corrector = FuzzyCorrector(knownTerms: ["watermelon", "the"])
        let suggestion = corrector.suggest(for: "teh")
        #expect(suggestion == "the")
    }

    // MARK: - 8. Case insensitive matching

    @Test("Case insensitive: 'RePoRt' matches 'report'")
    func testCaseInsensitive() {
        let corrector = FuzzyCorrector(knownTerms: ["report", "invoice"])
        let suggestion = corrector.suggest(for: "RePoRt")
        #expect(suggestion == nil) // exact match after case folding, no correction needed
    }

    @Test("Case insensitive typo: 'RePoR' suggests 'report'")
    func testCaseInsensitiveTypo() {
        let corrector = FuzzyCorrector(knownTerms: ["report", "invoice"])
        let suggestion = corrector.suggest(for: "RePoR")
        #expect(suggestion == "report")
    }
}
