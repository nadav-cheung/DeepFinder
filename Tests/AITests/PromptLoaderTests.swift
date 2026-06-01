import Foundation
import Testing
@testable import DeepFinder

@Suite("PromptLoader")
struct PromptLoaderTests {

    @Test("load returns nil for non-existent prompt")
    func loadNonExistentReturnsNil() {
        #expect(PromptLoader.load(name: "nonexistent_prompt") == nil)
    }

    @Test("PromptLoader is Sendable")
    func isSendable() {
        let loader = PromptLoader()
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(loader)
    }
}
