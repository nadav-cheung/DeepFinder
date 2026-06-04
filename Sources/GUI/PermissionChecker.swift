import AppKit
import Foundation

// MARK: - PermissionChecker

/// Checks Full Disk Access (FDA) and Accessibility permission status at runtime.
///
/// FDA is required for DeepFinder to index all files. Accessibility is required
/// for the global hotkey (⌃⌘K). This utility provides status checks and
/// convenience methods to open the relevant System Settings pages.
///
/// FDA detection uses the standard macOS approach: attempt to read a protected
/// system directory. If the read throws a sandbox/permission error, FDA is not granted.
enum PermissionChecker {

    // MARK: - FDA

    /// Whether Full Disk Access is currently granted.
    ///
    /// Uses the standard macOS detection approach: attempt to read a file that is
    /// protected by FDA. If the read succeeds, FDA is granted. If it throws a
    /// permission error, FDA is not granted.
    ///
    /// We check the user's Safari History database — a well-known FDA-protected
    /// path that is reliable across macOS versions. This matches the approach used
    /// by the community-standard `FullDiskAccess` Swift package.
    ///
    /// - Important: This only checks *read* access. FDA grants both read and write
    ///   to protected locations, but read-only detection is sufficient for our use case.
    static func isFDAGranted() -> Bool {
        let home = NSHomeDirectory()
        let protectedPath = "\(home)/Library/Safari/History.db"
        do {
            // Attempt to read the first byte of a FDA-protected file.
            // If FDA is granted, this succeeds. If not, it throws.
            let data = try Data(contentsOf: URL(fileURLWithPath: protectedPath), options: .alwaysMapped)
            return data.count > 0
        } catch {
            return false
        }
    }

    /// Opens System Settings > Privacy & Security > Full Disk Access.
    @MainActor
    static func openFDASettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility

    /// Whether Accessibility permission is currently granted.
    ///
    /// Delegates to `HotkeyPermissionHelper.isAccessibilityGranted()`.
    static func isAccessibilityGranted() -> Bool {
        HotkeyPermissionHelper.isAccessibilityGranted()
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    @MainActor
    static func openAccessibilitySettings() {
        HotkeyPermissionHelper.openAccessibilitySettings()
    }

    // MARK: - Status Stream

    /// Yields FDA status changes by polling every `interval` seconds.
    ///
    /// Useful for permission guide views that need to detect when the user
    /// grants FDA in System Settings and update the UI in real time.
    ///
    /// - Parameter interval: Polling interval in seconds. Defaults to 3.
    /// - Returns: An `AsyncStream` of `Bool` values representing FDA status.
    @MainActor
    static func fdaStatusStream(interval: TimeInterval = 3) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { @MainActor in
                var lastStatus = isFDAGranted()
                continuation.yield(lastStatus)

                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { break }
                    let current = isFDAGranted()
                    if current != lastStatus {
                        lastStatus = current
                        continuation.yield(current)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Yields Accessibility status changes by polling every `interval` seconds.
    ///
    /// - Parameter interval: Polling interval in seconds. Defaults to 3.
    /// - Returns: An `AsyncStream` of `Bool` values representing Accessibility status.
    @MainActor
    static func accessibilityStatusStream(interval: TimeInterval = 3) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { @MainActor in
                var lastStatus = isAccessibilityGranted()
                continuation.yield(lastStatus)

                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { break }
                    let current = isAccessibilityGranted()
                    if current != lastStatus {
                        lastStatus = current
                        continuation.yield(current)
                    }
                }
                continuation.finish()
            }
        }
    }
}
