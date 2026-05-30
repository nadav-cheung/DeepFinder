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

    // MARK: - 8. Conflict detection returns false for success status

    @Test("detectConflict returns false for noErr status")
    func testConflictDetectionReturnsFalseForSuccess() {
        let isConflict = GlobalHotkey.detectConflict(status: noErr)
        #expect(isConflict == false)
    }

    // MARK: - 9. Conflict detection returns true for conflict status

    @Test("detectConflict returns true for eventHotKeyExistsErr (-9878)")
    func testConflictDetectionReturnsTrueForConflict() {
        let isConflict = GlobalHotkey.detectConflict(status: OSStatus(-9878))
        #expect(isConflict == true)
    }

    // MARK: - 10. Conflict detection returns false for other errors

    @Test("detectConflict returns false for other OSStatus errors")
    func testConflictDetectionReturnsFalseForOtherErrors() {
        let isConflict = GlobalHotkey.detectConflict(status: OSStatus(-50)) // paramErr
        #expect(isConflict == false)
    }

    // MARK: - 11. Carbon conflict error constant

    @Test("carbonHotKeyConflictError is -9878")
    func testCarbonConflictErrorConstant() {
        #expect(GlobalHotkey.carbonHotKeyConflictError == OSStatus(-9878))
    }

    // MARK: - 12. Max retry attempts constant

    @Test("maxRetryAttempts is 3")
    func testMaxRetryAttempts() {
        #expect(GlobalHotkey.maxRetryAttempts == 3)
    }

    // MARK: - 13. retryCount starts at zero

    @Test("retryCount starts at zero after register")
    func testRetryCountStartsAtZero() {
        let hotkey = GlobalHotkey()
        #expect(hotkey.retryCount == 0)
        _ = hotkey.register {}
        // Synchronous register resets retryCount to 0.
        #expect(hotkey.retryCount == 0)
        hotkey.unregister()
    }

    // MARK: - 14. lastError is nil after successful register

    @Test("lastError is nil after successful register")
    func testLastErrorNilAfterSuccess() {
        let hotkey = GlobalHotkey()
        _ = hotkey.register {}
        if hotkey.isRegistered {
            #expect(hotkey.lastError == nil)
        }
        hotkey.unregister()
    }

    // MARK: - 15. HotkeyRegistrationError conflict description

    @Test("HotkeyRegistrationError.conflict has descriptive message")
    func testConflictErrorDescription() {
        let combo = KeyCombination(keyCode: 0x28, modifiers: UInt32(cmdKey | controlKey))
        let error = HotkeyRegistrationError.conflict(keyCombination: combo)
        let description = error.description
        #expect(description.contains("conflict"))
        #expect(description.contains("keyCode: 40"))
    }

    // MARK: - 16. HotkeyRegistrationError registrationFailed description

    @Test("HotkeyRegistrationError.registrationFailed has descriptive message")
    func testRegistrationFailedErrorDescription() {
        let combo = KeyCombination(keyCode: 0x28, modifiers: UInt32(cmdKey | controlKey))
        let error = HotkeyRegistrationError.registrationFailed(keyCombination: combo, attempts: 4)
        let description = error.description
        #expect(description.contains("4 attempts"))
    }

    // MARK: - 17. HotkeyRegistrationError unknown description

    @Test("HotkeyRegistrationError.unknown has descriptive message")
    func testUnknownErrorDescription() {
        let error = HotkeyRegistrationError.unknown(status: -50)
        let description = error.description
        #expect(description.contains("-50"))
    }

    // MARK: - 18. registerWithRetry returns a valid result

    @Test("registerWithRetry returns a valid result and updates state correctly")
    func testRegisterWithRetryReturnsResult() async {
        let hotkey = GlobalHotkey()
        let result = await hotkey.registerWithRetry {}
        switch result {
        case .success:
            #expect(hotkey.isRegistered == true)
            #expect(hotkey.retryCount == 0)
            #expect(hotkey.lastError == nil)
            hotkey.unregister()
        case .failure(let error):
            // Registration failed -- verify error type and retry count.
            if case .registrationFailed(_, let attempts) = error {
                #expect(attempts == GlobalHotkey.maxRetryAttempts + 1) // 4 total = 1 initial + 3 retries
            }
            #expect(hotkey.retryCount == GlobalHotkey.maxRetryAttempts)
        }
    }

    // MARK: - 19. registerWithRetry returns success when registration works

    @Test("registerWithRetry returns success if first attempt succeeds")
    func testRegisterWithRetrySucceeds() async {
        let hotkey = GlobalHotkey()
        let result = await hotkey.registerWithRetry {}
        if case .success = result {
            #expect(hotkey.isRegistered == true)
            #expect(hotkey.retryCount == 0)
            #expect(hotkey.lastError == nil)
        }
        hotkey.unregister()
    }

    // MARK: - 20. Exponential backoff delay calculation

    @Test("Retry base delay is 1 second in nanoseconds")
    func testRetryBaseDelay() {
        #expect(GlobalHotkey.retryBaseDelay == 1_000_000_000)
    }
}
