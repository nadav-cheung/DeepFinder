import AppKit
import XCTest

/// Bootstraps NSApplication for the test process.
///
/// GUI tests that create AppKit objects (NSWindow, SwiftUI views, NSWorkspace icons)
/// need a properly initialized NSApplication to avoid SEGV crashes during
/// autorelease pool cleanup. Without NSApp, Core Animation transactions commit
/// objects into an autorelease pool that crashes on drain (objc_release of
/// NSConcretePointerArray in QLFadeWindowEffect / CA::Context).
///
/// This XCTestCase is discovered by the test runner automatically.
/// Its one-time setUp creates NSApplication.shared if not already present.
final class GUIBootstrapTestCase: XCTestCase {

    override class func setUp() {
        super.setUp()
        if NSApp == nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
        }
        // Disable Core Animation render-server connections in the test process.
        // Prevents CA::Display::DisplayLink from dispatching stale items that
        // crash during objc_autoreleasePoolPop.
        setenv("CA_DISABLE_RENDER_SERVER", "1", 1)
    }

    /// Dummy test so the test runner doesn't skip this class.
    func testBootstrap() {
        // NSApp is guaranteed to exist after setUp.
        XCTAssertNotNil(NSApp)
    }
}
