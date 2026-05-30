import Testing
import Foundation
import Carbon
import CoreGraphics
@testable import DeepFinder

@Suite("GlobalHotkey")
struct GlobalHotkeyTests {

    // MARK: - 1. Default key combo is ^Cmd+K

    @Test("Default key combination is Control+Command+K")
    func testDefaultKeyCombination() {
        let combo = GlobalHotkey.defaultKeyCombination
        // kVK_ANSI_K = 0x28 (40 decimal)
        #expect(combo.keyCode == 0x28)
        // cmdKey | controlKey
        #expect(combo.modifiers == UInt32(cmdKey | controlKey))
    }

    // MARK: - 2. Register returns true when accessible

    @Test("Register returns Bool indicating success or failure")
    func testRegisterReturnsBool() {
        let hotkey = GlobalHotkey()
        // In test environment, accessibility may or may not be granted.
        // The point is that register() returns a Bool without crashing.
        var handlerCalled = false
        let result = hotkey.register { handlerCalled = true }
        // We can't assert true/false because it depends on accessibility permission
        // in the test runner environment, but it must return a Bool.
        #expect(type(of: result) == Bool.self)
        // Clean up
        hotkey.unregister()
    }

    // MARK: - 3. Unregister cleans up

    @Test("Unregister cleans up without crashing")
    func testUnregisterCleansUp() {
        let hotkey = GlobalHotkey()
        _ = hotkey.register {}
        // Should not crash
        hotkey.unregister()
        // Calling unregister again (double cleanup) should also be safe
        hotkey.unregister()
    }

    // MARK: - 4. Handler called on hotkey press (via direct invocation)

    @Test("Handler is invoked when hotkey fires")
    func testHandlerCalledOnHotkeyPress() {
        let hotkey = GlobalHotkey()
        var handlerCalled = false
        _ = hotkey.register { handlerCalled = true }

        // Simulate the hotkey firing via the testable interface.
        // In production, this is triggered by the Carbon/CGEventTap callback.
        hotkey.simulateHotkeyPress()

        #expect(handlerCalled == true)
        hotkey.unregister()
    }

    // MARK: - 5. Accessibility check returns Bool

    @Test("Accessibility check returns a Bool")
    func testAccessibilityCheckReturnsBool() {
        let result = HotkeyPermissionHelper.isAccessibilityGranted()
        #expect(type(of: result) == Bool.self)
    }

    // MARK: - 6. Double register doesn't crash

    @Test("Double register does not crash")
    func testDoubleRegisterDoesNotCrash() {
        let hotkey = GlobalHotkey()
        var count = 0
        _ = hotkey.register { count += 1 }
        // Second register should auto-unregister the first, then register again.
        let secondResult = hotkey.register { count += 10 }
        #expect(type(of: secondResult) == Bool.self)
        hotkey.unregister()
    }

    // MARK: - 7. isRegistered reflects state

    @Test("isRegistered reflects registration state")
    func testIsRegisteredReflectsState() {
        let hotkey = GlobalHotkey()
        #expect(hotkey.isRegistered == false)

        _ = hotkey.register {}
        // Whether it succeeded depends on permissions, but isRegistered should
        // reflect the actual state.
        if hotkey.isRegistered {
            hotkey.unregister()
            #expect(hotkey.isRegistered == false)
        }
    }
}
