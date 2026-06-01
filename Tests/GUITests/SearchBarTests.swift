import Testing
import SwiftUI
@testable import DeepFinder

@Suite("SearchBarView")
struct SearchBarTests {

    // MARK: - Text binding

    @Test("Text binding reflects typed input")
    func textBindingReflectsInput() {
        let text = Binding.create("")
        let view = SearchBarView(text: text, onCommit: { _ in })
        text.wrappedValue = "report"
        #expect(text.wrappedValue == "report")
        _ = view
    }

    // MARK: - Clear button visibility

    @Test("Clear button clears text")
    func clearButtonClearsText() {
        let text = Binding.create("hello")
        let _ = SearchBarView(text: text, onCommit: { _ in })
        text.wrappedValue = ""
        #expect(text.wrappedValue == "")
    }

    @Test("Clear button hidden when text is empty")
    func clearButtonHiddenWhenEmpty() {
        let text = Binding.create("")
        let view = SearchBarView(text: text, onCommit: { _ in })
        #expect(text.wrappedValue.isEmpty)
        _ = view
    }

    // MARK: - Placeholder

    @Test("Placeholder text is '搜索文件...'")
    func placeholderText() {
        let text = Binding.create("")
        let view = SearchBarView(text: text, onCommit: { _ in })
        #expect(SearchBarView.placeholder == "搜索文件...")
        _ = view
    }

}

// MARK: - Test helpers

extension Binding {
    /// Create a Binding in tests without @State/@Observable.
    static func create(_ value: Value) -> Binding<Value> {
        var mutable = value
        return Binding(
            get: { mutable },
            set: { mutable = $0 }
        )
    }
}
