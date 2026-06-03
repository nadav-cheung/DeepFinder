import SwiftUI

// MARK: - KeyboardHintBar

/// A thin horizontal bar displaying keyboard shortcut hints for result actions.
///
/// REQ-3.2-06: Shows a compact row of shortcut labels separated by thin dividers.
/// Shortcut symbols use monospaced design for alignment; descriptive text uses
/// the system font at size 11 in secondary color.
struct KeyboardHintBar: View {

    // MARK: - Hint Model

    private struct Hint: Identifiable {
        let symbol: String
        let label: String
        var id: String { symbol + label }
    }

    // MARK: - REQ-3.2-37: Testable hint count

    /// Number of hints displayed. Exposed for testing.
    static let expectedHintCount = 6

    // MARK: - Hints

    private let hints: [Hint] = [
        Hint(symbol: "↵", label: "打开"),
        Hint(symbol: "⌘↵", label: "Finder"),
        Hint(symbol: "Space", label: "预览"),
        Hint(symbol: "⌘C", label: "路径"),
        Hint(symbol: "⌘K", label: "操作"),
        Hint(symbol: "⌘I", label: "详情")   // REQ-3.2-37
    ]

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(hints.enumerated()), id: \.element.id) { index, hint in
                if index > 0 {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: 10)
                        .padding(.horizontal, 6)
                }

                HStack(spacing: 3) {
                    Text(hint.symbol)
                        .monospaced()
                    Text(hint.label)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
    }
}
