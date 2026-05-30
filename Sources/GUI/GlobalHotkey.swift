import Foundation
import Carbon
import CoreGraphics

// MARK: - KeyCombination

/// A keyboard shortcut consisting of a virtual key code and Carbon modifier flags.
///
/// Uses Carbon virtual key codes (e.g. `kVK_ANSI_K`) and Carbon modifier flags
/// (`cmdKey`, `controlKey`, etc.) because `RegisterEventHotKey` requires this format.
struct KeyCombination: Sendable, Equatable {
    /// Carbon virtual key code (e.g. `kVK_ANSI_K` = 0x28).
    let keyCode: UInt32
    /// Carbon modifier flags (e.g. `cmdKey | controlKey`).
    let modifiers: UInt32
}

// MARK: - GlobalHotkey

/// Registers a system-wide keyboard shortcut that fires even when the app is not frontmost.
///
/// Uses Carbon `RegisterEventHotKey` as the primary API (reliable, well-tested).
/// Falls back to `CGEventTap` if the Carbon API fails (e.g. future deprecation).
///
/// **Thread safety**: `@unchecked Sendable` because all mutable state is protected by
/// `lock` (an `NSLock`). The Carbon callback fires on the main run loop thread and
/// serializes through the lock before touching mutable state.
///
/// **Lifecycle**:
/// - Call `register(handler:)` to activate.
/// - Call `unregister()` to tear down, or let `deinit` handle it.
/// - Calling `register` while already registered auto-unregisters first.
final class GlobalHotkey: @unchecked Sendable {

    // MARK: - Constants

    /// Default hotkey: Control+Command+K (⌃⌘K).
    static let defaultKeyCombination = KeyCombination(
        keyCode: UInt32(kVK_ANSI_K), // 0x28
        modifiers: UInt32(cmdKey | controlKey)
    )

    // MARK: - State

    private let lock = NSLock()

    /// The key combination to register.
    let keyCombination: KeyCombination

    /// Whether the hotkey is currently registered with the system.
    private(set) var isRegistered: Bool = false

    /// The user-provided handler to invoke when the hotkey fires.
    private var handler: (() -> Void)?

    // Carbon state
    private var hotKeyRef: EventHotKeyRef?

    // CGEventTap state -- fileprivate so the file-level CGEventTap callback can access them.
    fileprivate var eventTap: CFMachPort?
    fileprivate var runLoopSource: CFRunLoopSource?

    /// Which backend is currently active.
    private var activeBackend: Backend = .none

    private enum Backend {
        case none
        case carbon
        case cgEventTap
    }

    // MARK: - Carbon event handler

    /// One-time installed Carbon event handler reference. Lives for the instance lifetime.
    private var carbonHandlerRef: EventHandlerRef?

    // MARK: - Init

    init(keyCombination: KeyCombination = defaultKeyCombination) {
        self.keyCombination = keyCombination
    }

    deinit {
        unregister()
    }

    // MARK: - Register

    /// Register the global hotkey with the system.
    ///
    /// Attempts `RegisterEventHotKey` first. If that fails, falls back to `CGEventTap`.
    /// - Parameter handler: Closure to invoke when the hotkey is pressed.
    /// - Returns: `true` if registration succeeded, `false` otherwise.
    func register(handler: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Auto-unregister if already registered.
        if isRegistered {
            unregisterLocked()
        }

        self.handler = handler

        // Attempt Carbon RegisterEventHotKey first.
        if registerCarbon() {
            return true
        }

        // Fallback to CGEventTap.
        if registerCGEventTap() {
            return true
        }

        self.handler = nil
        return false
    }

    // MARK: - Unregister

    /// Tear down the global hotkey registration.
    ///
    /// Safe to call multiple times. Safe to call when not registered.
    func unregister() {
        lock.lock()
        defer { lock.unlock() }
        unregisterLocked()
    }

    // MARK: - Test Support

    /// Simulates a hotkey press for testing.
    ///
    /// Directly invokes the stored handler, bypassing the system event machinery.
    /// This allows tests to verify handler wiring without Accessibility permissions.
    func simulateHotkeyPress() {
        lock.lock()
        let h = handler
        lock.unlock()
        h?()
    }

    // MARK: - Private: Carbon Backend

    private func registerCarbon() -> Bool {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = fourCharCode("DfHk") // DeepFinder Hotkey
        hotKeyID.id = keyCombination.keyCode

        // Install the Carbon event handler (once per instance).
        installCarbonEventHandlerIfNeeded()

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCombination.keyCode,
            keyCombination.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let ref = hotKeyRef else {
            return false
        }

        self.hotKeyRef = ref
        self.activeBackend = .carbon
        self.isRegistered = true
        return true
    }

    /// Installs the Carbon event handler on first registration.
    /// The handler lives for the lifetime of the `GlobalHotkey` instance.
    private func installCarbonEventHandlerIfNeeded() {
        guard carbonHandlerRef == nil else { return }

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Pass self as userData so the callback can reach the instance.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotkeyCarbonCallback,
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        if status == noErr {
            carbonHandlerRef = handlerRef
        }
    }

    /// Called from the Carbon event handler callback.
    fileprivate func handleCarbonHotkey() {
        lock.lock()
        let h = handler
        lock.unlock()
        h?()
    }

    private func unregisterLocked() {
        switch activeBackend {
        case .carbon:
            if let ref = hotKeyRef {
                UnregisterEventHotKey(ref)
                self.hotKeyRef = nil
            }
            // Remove the installed event handler.
            if let handlerRef = carbonHandlerRef {
                RemoveEventHandler(handlerRef)
                self.carbonHandlerRef = nil
            }

        case .cgEventTap:
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
                self.runLoopSource = nil
            }
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                self.eventTap = nil
            }

        case .none:
            break
        }

        activeBackend = .none
        isRegistered = false
        handler = nil
    }

    // MARK: - Private: CGEventTap Backend

    private func registerCGEventTap() -> Bool {
        // Build the event mask: keyDown only.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // Pass unretained self as userInfo for the callback.
        let info = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: globalHotkeyCGEventCallback,
            userInfo: info
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.activeBackend = .cgEventTap
        self.isRegistered = true
        return true
    }

    /// Called from the CGEventTap callback on the run loop thread.
    fileprivate func handleCGEvent(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))

        // Check modifier match.
        let carbonModifiers = cgFlagsToCarbonModifiers(flags)
        guard carbonModifiers == keyCombination.modifiers else { return }

        // Check key code match.
        guard keyCode == keyCombination.keyCode else { return }

        // Fire the handler.
        lock.lock()
        let h = handler
        lock.unlock()
        h?()
    }

    // MARK: - Private: Helpers

    /// Convert a four-character string to a FourCharCode / OSType.
    private func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in string.utf8 {
            result = (result << 8) | FourCharCode(char)
        }
        return result
    }

    /// Convert CGEventFlags to Carbon modifier flags for comparison.
    private func cgFlagsToCarbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.maskCommand) { carbon |= UInt32(cmdKey) }
        if flags.contains(.maskControl) { carbon |= UInt32(controlKey) }
        if flags.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        return carbon
    }
}

// MARK: - Carbon Event Handler Callback

/// C-style callback for Carbon `InstallEventHandler`.
///
/// Reads the `GlobalHotkey` instance from `userData` and dispatches to
/// `handleCarbonHotkey()`.
private func globalHotkeyCarbonCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return status }

    // Verify this is our hotkey (signature "DfHk").
    let expectedSignature: FourCharCode = "DfHk".utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    guard hotKeyID.signature == expectedSignature else {
        return OSStatus(eventNotHandledErr)
    }

    // Retrieve the GlobalHotkey instance from userData.
    if let userData = userData {
        let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
        hotkey.handleCarbonHotkey()
    }

    return noErr
}

// MARK: - CGEventTap Callback

/// C-style callback for `CGEvent.tapCreate`.
///
/// Reads the `GlobalHotkey` instance from `userInfo` and delegates event handling.
private func globalHotkeyCGEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }

    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userInfo).takeUnretainedValue()

    // Handle tap being disabled by the system (e.g. timeout).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = hotkey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    hotkey.handleCGEvent(event)
    return Unmanaged.passUnretained(event)
}
