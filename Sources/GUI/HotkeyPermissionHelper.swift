import Foundation
import AppKit
@preconcurrency import Carbon

// MARK: - HotkeyPermissionHelper

/// Utility for checking and requesting Accessibility permissions required for global hotkeys.
///
/// `RegisterEventHotKey` requires Accessibility (AX) permission on macOS.
/// `CGEventTap` requires Input Monitoring permission. Both are TCC-protected.
///
/// This helper provides a unified interface for:
/// 1. Checking current permission state
/// 2. Requesting permission via the system prompt
/// 3. Guiding the user to System Settings if the prompt was dismissed
struct HotkeyPermissionHelper {

    // MARK: - Check Permission

    /// Check whether Accessibility permission is currently granted.
    ///
    /// - Returns: `true` if the app is trusted for Accessibility.
    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Request Permission

    /// Request Accessibility permission by showing the system prompt.
    ///
    /// This triggers the macOS TCC dialog asking the user to grant Accessibility
    /// access to DeepFinder. If already granted, this is a no-op.
    ///
    /// - Returns: `true` if permission was already granted (no prompt needed),
    ///   `false` if a prompt was shown or permission is not yet granted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // Use the string literal directly to avoid Swift 6 concurrency-safety error
        // with the C global `kAXTrustedCheckOptionPrompt`. The value is guaranteed
        // by Apple to be "AXTrustedCheckOptionPrompt" (documented, stable ABI).
        let promptOption: CFString = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptOption: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Prompt if Not Granted

    /// Check permission and show an alert guiding the user if not granted.
    ///
    /// Shows a user-friendly NSAlert explaining why Accessibility is needed,
    /// with a button to open System Settings > Accessibility.
    ///
    /// - Returns: `true` if permission is already granted, `false` if the
    ///   user was prompted (permission not yet granted).
    @MainActor
    @discardableResult
    static func promptIfNotGranted() -> Bool {
        if isAccessibilityGranted() {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "\(Product.name) needs Accessibility access"
        alert.informativeText =
            "To register the global hotkey (⌃⌘K), \(Product.name) requires Accessibility permission.\n\n"
            + "Please open System Settings > Privacy & Security > Accessibility "
            + "and enable \(Product.name)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }

        return false
    }

    // MARK: - Open System Settings

    /// Open the Accessibility pane in System Settings.
    @MainActor
    static func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
