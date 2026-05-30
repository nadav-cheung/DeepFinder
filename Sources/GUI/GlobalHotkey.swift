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

// MARK: - HotkeyRegistrationError

/// Errors that can occur during global hotkey registration.
enum HotkeyRegistrationError: Error, Sendable, CustomStringConvertible {
    /// Another application has already registered this key combination.
    case conflict(keyCombination: KeyCombination)
    /// Registration failed after exhausting all retries.
    case registrationFailed(keyCombination: KeyCombination, attempts: Int)
    /// Registration failed for an unknown reason.
    case unknown(status: OSStatus)

    var description: String {
        switch self {
        case .conflict(let combo):
            return "Hotkey conflict: another app has registered the same key combination (keyCode: \(combo.keyCode), modifiers: \(combo.modifiers))"
        case .registrationFailed(let combo, let attempts):
            return "Hotkey registration failed after \(attempts) attempts for key combination (keyCode: \(combo.keyCode), modifiers: \(combo.modifiers))"
        case .unknown(let status):
            return "Hotkey registration failed with OSStatus \(status)"
        }
    }
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

    /// Carbon error code returned when another app has already registered the same hotkey.
    ///
    /// `RegisterEventHotKey` returns `eventHotKeyExistsErr` (-9878) when the key combination
    /// is already claimed by another process.
    static let carbonHotKeyConflictError: OSStatus = -9878

    /// Maximum number of retry attempts when registration fails.
    static let maxRetryAttempts = 3

    /// Exponential backoff base delay in seconds for retries.
    /// Attempt 1: 1s, Attempt 2: 2s, Attempt 3: 4s.
    static let retryBaseDelay: UInt64 = 1_000_000_000 // 1 second in nanoseconds

    // MARK: - State

    private nonisolated(unsafe) let lock = NSLock()

    /// The key combination to register.
    let keyCombination: KeyCombination

    /// Whether the hotkey is currently registered with the system.
    private(set) var isRegistered: Bool = false

    /// The user-provided handler to invoke when the hotkey fires.
    private var handler: (() -> Void)?

    /// Number of retry attempts made during the most recent registration.
    private(set) var retryCount: Int = 0

    /// The last registration error, if any.
    private(set) var lastError: HotkeyRegistrationError?

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

    // MARK: - Conflict Detection

    /// Detects whether the given Carbon registration status indicates a hotkey conflict.
    ///
    /// A conflict occurs when another application has already registered the same key
    /// combination. Carbon returns `eventHotKeyExistsErr` (-9878) in this case.
    ///
    /// - Parameter status: The `OSStatus` returned by `RegisterEventHotKey`.
    /// - Returns: `true` if the status indicates a conflict.
    static func detectConflict(status: OSStatus) -> Bool {
        return status == carbonHotKeyConflictError
    }

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
        retryCount = 0
        lastError = nil

        // Attempt Carbon RegisterEventHotKey first.
        if registerCarbon() {
            return true
        }

        // Fallback to CGEventTap.
        if registerCGEventTap() {
            lastError = nil // Carbon failed but CGEventTap succeeded; clear the error.
            return true
        }

        self.handler = nil
        return false
    }

    // MARK: - Register with Retry

    /// Register the global hotkey with exponential backoff retry.
    ///
    /// If registration fails (non-conflict), retries up to `maxRetryAttempts` times
    /// with exponential backoff: 1s, 2s, 4s. Conflict errors are not retried because
    /// the key combination is held by another process.
    ///
    /// - Parameter handler: Closure to invoke when the hotkey is pressed.
    /// - Returns: `.success` if registered, or a `HotkeyRegistrationError` describing the failure.
    func registerWithRetry(handler: @escaping @Sendable () -> Void) async -> Result<Void, HotkeyRegistrationError> {
        setUpForRegistration(handler: handler)

        for attempt in 0...Self.maxRetryAttempts {
            let (success, carbonStatus) = attemptCarbonRegistration()

            if success {
                return .success(())
            }

            // Check for conflict -- don't retry.
            if Self.detectConflict(status: carbonStatus) {
                let error = HotkeyRegistrationError.conflict(keyCombination: keyCombination)
                recordError(error)
                return .failure(error)
            }

            // If we have more retries left, wait with exponential backoff.
            if attempt < Self.maxRetryAttempts {
                setRetryCount(attempt + 1)
                let delayNs = Self.retryBaseDelay * UInt64(1 << attempt)
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }

        let error = HotkeyRegistrationError.registrationFailed(
            keyCombination: keyCombination,
            attempts: Self.maxRetryAttempts + 1
        )
        recordErrorAndClearHandler(error)
        return .failure(error)
    }

    // MARK: - Synchronous Lock Helpers (bridging async/sync boundary)

    /// Prepares state for a new registration attempt. Called from async context.
    private func setUpForRegistration(handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if isRegistered {
            unregisterLocked()
        }
        self.handler = handler
        retryCount = 0
        lastError = nil
        lock.unlock()
    }

    /// Attempts Carbon registration and returns (success, lastStatus). Called from async context.
    private func attemptCarbonRegistration() -> (Bool, OSStatus) {
        lock.lock()
        let success = registerCarbonInternal()
        let status = lastCarbonStatus
        lock.unlock()
        return (success, status)
    }

    /// Records an error in lastError. Called from async context.
    private func recordError(_ error: HotkeyRegistrationError) {
        lock.lock()
        lastError = error
        lock.unlock()
    }

    /// Records an error and clears the handler. Called from async context.
    private func recordErrorAndClearHandler(_ error: HotkeyRegistrationError) {
        lock.lock()
        lastError = error
        handler = nil
        lock.unlock()
    }

    /// Updates retryCount. Called from async context.
    private func setRetryCount(_ count: Int) {
        lock.lock()
        retryCount = count
        lock.unlock()
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

    /// The OSStatus from the most recent `RegisterEventHotKey` call.
    /// Used for conflict detection and error reporting.
    private var lastCarbonStatus: OSStatus = noErr

    private func registerCarbon() -> Bool {
        // Delegate to internal method; caller holds the lock.
        return registerCarbonInternal()
    }

    /// Internal Carbon registration that also captures the status code.
    /// Caller must hold `lock`.
    private func registerCarbonInternal() -> Bool {
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

        lastCarbonStatus = status

        guard status == noErr, let ref = hotKeyRef else {
            if Self.detectConflict(status: status) {
                lastError = .conflict(keyCombination: keyCombination)
            } else if status != noErr {
                lastError = .unknown(status: status)
            }
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
