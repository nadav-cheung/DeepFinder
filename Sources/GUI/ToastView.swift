import SwiftUI

// MARK: - ToastItem

/// Data model for a single toast notification.
struct ToastItem: Identifiable, Equatable {
    let message: String
    let id: UUID

    init(message: String, id: UUID = UUID()) {
        self.message = message
        self.id = id
    }
}

// MARK: - ToastOverlay (ViewModifier)

/// Positions a toast at the top center of its parent, auto-dismissing after
/// a fixed interval.
///
/// The toast appears as a compact pill with a `.regularMaterial` background
/// and medium-weight 12pt text. It transitions in from the top edge with a
/// spring animation (subtle scale + opacity) and dismisses itself after
/// 1.5 seconds.
struct ToastOverlay: ViewModifier {

    /// The current toast to display. Set to `nil` to dismiss.
    @Binding var item: ToastItem?

    /// Duration in seconds before the toast auto-dismisses.
    private let displayDuration: Double

    @State private var dismissTask: Task<Void, Never>?

    init(item: Binding<ToastItem?>, displayDuration: Double = 1.5) {
        self._item = item
        self.displayDuration = displayDuration
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let item {
                    toastView(for: item)
                        .scaleEffect(1.0)
                        .transition(
                            .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95))
                        )
                        .onAppear { scheduleDismiss() }
                        .onDisappear { cancelDismiss() }
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: item?.id)
    }

    // MARK: - Subviews

    private func toastView(for item: ToastItem) -> some View {
        Text(item.message)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    // MARK: - Auto-Dismiss

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(displayDuration))
            guard !Task.isCancelled else { return }
            withAnimation { self.item = nil }
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}

// MARK: - ToastModifier (convenience ViewModifier)

/// Convenience modifier that manages its own `@State` toast item,
/// so callers only need to set the message.
struct ToastModifier: ViewModifier {

    /// Set to a non-nil message to present a toast.
    @Binding var message: String?

    @State private var item: ToastItem?

    func body(content: Content) -> some View {
        content
            .onChange(of: message) { _, newValue in
                if let newValue {
                    item = ToastItem(message: newValue)
                    // Clear the binding so the caller can re-trigger with the same message.
                    message = nil
                }
            }
            .modifier(ToastOverlay(item: $item))
    }
}

// MARK: - View Extension

extension View {

    /// Present a transient toast notification at the top center of this view.
    ///
    /// Set `message` to a non-nil string to trigger the toast. The binding is
    /// automatically reset to `nil` after the toast appears, so re-triggering
    /// with the same string works without extra state management.
    ///
    /// - Parameter message: Binding to an optional message string.
    /// - Returns: A view with toast overlay capability.
    func showToast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
