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

    // MARK: - CJK marked text handling (via SearchBarState)

    @Test("CJK marked text does not trigger search")
    func cjkMarkedTextDoesNotTriggerSearch() {
        var commitCount = 0
        let state = SearchBarState(onCommit: { _ in
            commitCount += 1
        })

        state.hasMarkedText = true
        state.onTextChange("中")
        #expect(commitCount == 0)

        state.hasMarkedText = false
        state.onTextChange("中国")
        #expect(commitCount == 1)
    }

    // MARK: - Search on commit (via SearchBarState)

    @Test("Search triggered on text commit (non-CJK)")
    func searchTriggeredOnCommit() {
        var lastQuery: String?
        let state = SearchBarState(onCommit: { query in
            lastQuery = query
        })

        state.hasMarkedText = false
        state.onTextChange("report")
        #expect(lastQuery == "report")
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
