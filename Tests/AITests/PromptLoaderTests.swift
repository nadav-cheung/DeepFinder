import Foundation
import Testing
@testable import DeepFinder

@Suite("PromptLoader")
struct PromptLoaderTests {

    @Test("load returns nil for non-existent prompt")
    func loadNonExistentReturnsNil() {
        #expect(PromptLoader.load(name: "nonexistent_prompt") == nil)
    }

    // MARK: - Edge cases

    @Test("load returns nil for empty string name")
    func loadEmptyNameReturnsNil() {
        #expect(PromptLoader.load(name: "") == nil)
    }

    @Test("load handles special characters in name without crashing")
    func loadSpecialCharactersNoCrash() {
        // These should all return nil (no matching file) but must not crash
        #expect(PromptLoader.load(name: "prompt/with/slashes") == nil)
        #expect(PromptLoader.load(name: "prompt.with.dots") == nil)
        #expect(PromptLoader.load(name: "prompt with spaces") == nil)
        #expect(PromptLoader.load(name: "prompt-with-dashes") == nil)
        #expect(PromptLoader.load(name: "prompt_with_underscores") == nil)
    }

    @Test("load handles Unicode characters in name without crashing")
    func loadUnicodeNameNoCrash() {
        #expect(PromptLoader.load(name: "中文提示") == nil)
        #expect(PromptLoader.load(name: "прошка") == nil)
        #expect(PromptLoader.load(name: "プロンプト") == nil)
        #expect(PromptLoader.load(name: "emoji🎉prompt") == nil)
    }

    @Test("load handles very long name without crashing")
    func loadVeryLongNameNoCrash() {
        let longName = String(repeating: "a", count: 10000)
        #expect(PromptLoader.load(name: longName) == nil)
    }

    @Test("concurrent calls to load do not crash and return consistent results")
    func concurrentAccessNoCrash() async {
        // Call load from many concurrent tasks to verify thread safety
        // (PromptLoader is a struct with a static method using only value types)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let name = "concurrent_prompt_\(i)"
                    let result = PromptLoader.load(name: name)
                    // All should return nil since no files exist
                    #expect(result == nil)
                }
            }
        }
    }

    @Test("repeated calls with same name return same result")
    func repeatedCallsReturnSameResult() {
        let name = "repeated_test_prompt"
        let result1 = PromptLoader.load(name: name)
        let result2 = PromptLoader.load(name: name)
        let result3 = PromptLoader.load(name: name)
        #expect(result1 == result2)
        #expect(result2 == result3)
    }
}
