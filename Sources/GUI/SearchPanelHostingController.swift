import AppKit
import SwiftUI

// MARK: - SearchPanel

/// A floating NSPanel that can become the key window so its text field
/// accepts keyboard input. Required because `.nonactivatingPanel` alone
/// prevents the window from becoming key, which blocks all text entry.
///
/// Only `canBecomeKey` is overridden — `canBecomeMain` stays `false` so
/// the panel doesn't appear in the Cmd+` window cycle.
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SearchPanelHostingController

/// NSPanel controller that hosts `SearchPanelView`.
///
/// Creates a floating, titleless NSPanel with Liquid Glass material.
/// Centers on the active screen (determined by mouse location).
/// Dismisses on click-outside or Esc key.
///
/// REQ-3.2-07: panel height accommodates at least 20 result rows.
/// REQ-3.2-19: animated open/close with spring-like feel.
///
/// Reopening preserves the search text via the shared `SearchViewModel`.
@MainActor
public final class SearchPanelHostingController {

    private var panel: NSPanel?
    private let viewModel: SearchViewModel

    /// Fixed search bar height (padding + text field).
    private static let searchBarHeight: CGFloat = 48

    /// Height for 20 result rows (REQ-3.2-07).
    private static let minResultsHeight: CGFloat = CGFloat(ResultsListState.minVisibleRows) * ResultsListState.rowHeight

    /// Top padding from screen edge.
    private static let topPaddingRatio: CGFloat = 0.15

    /// Bottom margin.
    private static let bottomMargin: CGFloat = 20

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Panel Lifecycle

    /// Show the search panel, centering on the screen where the mouse is located.
    ///
    /// REQ-3.2-19: panel animates from search-bar-only height to full height.
    func show() {
        if let existingPanel = panel, existingPanel.isVisible {
            existingPanel.makeKeyAndOrderFront(nil)
            existingPanel.makeFirstResponder(existingPanel.contentView)
            return
        }

        let targetScreen = screenForMouseLocation()
        let panelWidth = clampedPanelWidth(for: targetScreen)

        // REQ-3.2-19: start at search-bar-only height, animate to full height.
        let startHeight = Self.searchBarHeight
        let targetHeight = clampedPanelHeight(for: targetScreen)

        let startSize = NSSize(width: panelWidth, height: startHeight)
        let targetSize = NSSize(width: panelWidth, height: targetHeight)
        let origin = centerOnScreen(targetScreen, size: targetSize)

        let newPanel = SearchPanel(
            contentRect: NSRect(origin: origin, size: startSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        newPanel.level = .floating
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = false
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false

        // Dismiss when the user clicks outside (another app gains active status).
        // Safe now that `NSApplicationSupportsAutomaticTermination = NO` is set in
        // Info.plist — AppKit will not auto-terminate the app when the panel hides.
        newPanel.hidesOnDeactivate = true

        // Host SwiftUI view — set as contentView directly so first-responder
        // chaining works correctly for the TextField.
        let hostingView = NSHostingView(rootView: SearchPanelView(viewModel: viewModel))
        hostingView.frame = newPanel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView

        self.panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        newPanel.makeFirstResponder(hostingView)

        // REQ-3.2-19: animate from search-bar-only to full height.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            context.allowsImplicitAnimation = true
            newPanel.animator().setFrame(
                NSRect(origin: origin, size: targetSize),
                display: true
            )
        }
    }

    /// Hide the panel without destroying it (preserves search text).
    /// REQ-3.2-19: animated collapse to search-bar height before ordering out.
    func hide() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let collapsedFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height - Self.searchBarHeight,
            width: currentFrame.width,
            height: Self.searchBarHeight
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.completionHandler = { panel.orderOut(nil) }
            panel.animator().setFrame(collapsedFrame, display: true)
        }
    }

    /// Toggle panel visibility.
    func toggle() {
        if let p = panel, p.isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Screen Positioning

    /// Find the screen containing the mouse cursor, falling back to main or first screen.
    private func screenForMouseLocation() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }

        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Clamp panel width: min 480, max 800, no wider than screen minus margins.
    private func clampedPanelWidth(for screen: NSScreen) -> CGFloat {
        let margin: CGFloat = 80
        let maxFromScreen = screen.visibleFrame.width - margin * 2
        return min(max(480, maxFromScreen), 800)
    }

    /// Compute target panel height: search bar + results area, clamped to screen bounds.
    /// REQ-3.2-07: at least 20 rows visible, but not exceeding screen space.
    private func clampedPanelHeight(for screen: NSScreen) -> CGFloat {
        let screenFrame = screen.visibleFrame
        let topPadding = screenFrame.height * Self.topPaddingRatio
        let maxAvailable = screenFrame.height - topPadding - Self.bottomMargin

        let idealHeight = Self.searchBarHeight + Self.minResultsHeight

        return min(idealHeight, maxAvailable)
    }

    /// Compute origin to center the panel near the top of the given screen.
    private func centerOnScreen(_ screen: NSScreen, size: NSSize) -> NSPoint {
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let topPadding: CGFloat = screenFrame.height * Self.topPaddingRatio
        let y = screenFrame.maxY - topPadding - size.height
        return NSPoint(x: x, y: y)
    }
}
