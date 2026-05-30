import SwiftUI

// MARK: - SettingsWindow

/// NSWindow wrapper for the Settings panel.
///
/// Provides a standard macOS settings window with toolbar-style tabs.
/// Keyboard shortcut: Cmd+, opens the settings window.
struct SettingsWindow {

    /// Create the settings NSWindow.
    ///
    /// - Parameter configProvider: The config provider (IPC in production, mock in tests).
    /// - Returns: A configured NSWindow ready to be displayed.
    @MainActor
    static func createWindow(configProvider: some SettingsConfigProvider) -> NSWindow {
        let viewModel = SettingsViewModel(configProvider: configProvider)
        let view = SettingsView(viewModel: viewModel)

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Product.name) Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.minSize = NSSize(width: 480, height: 360)

        return window
    }
}

// MARK: - Settings Keyboard Shortcut (Cmd+,)

/// Overlay that registers Cmd+, as a keyboard shortcut to toggle the settings window.
///
/// Uses a hidden Button with `.keyboardShortcut(",", modifiers: .command)` so the
/// shortcut is registered in SwiftUI's responder chain.
struct SettingsShortcutOverlay: View {

    @Binding var isPresented: Bool

    var body: some View {
        // Hidden button captures Cmd+, and toggles the settings window.
        Button {
            isPresented.toggle()
        } label: {
            EmptyView()
        }
        .keyboardShortcut(",", modifiers: .command)
        .hidden()
    }
}
