import AVFoundation
import Speech
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

// MARK: - SpeechAuthorizationStatus

/// Authorization status for speech recognition features.
///
/// Combines both Speech Recognition (SFSpeechRecognizer) and
/// Microphone (AVAudioApplication) permission states into a single
/// unified status. Both must be `.authorized` for speech input to work.
///
/// REQ-3.0-12: Speech authorization flow.
public enum SpeechAuthorizationStatus: Sendable, Equatable {
    /// Permissions have not been requested yet.
    case notDetermined
    /// The user denied one or both permissions.
    case denied
    /// Speech recognition is restricted on this device (e.g., parental controls).
    case restricted
    /// Both Speech Recognition and Microphone access are granted.
    case authorized
}

// MARK: - SpeechPermissionChecker (protocol)

/// Protocol abstracting permission checks for testability.
///
/// Production uses `LiveSpeechPermissionChecker` which calls Apple framework APIs.
/// Tests inject a mock that returns canned statuses.
public protocol SpeechPermissionChecker: Sendable {
    /// Current speech recognition authorization status.
    var speechStatus: SFSpeechRecognizerAuthorizationStatus { get async }
    /// Current microphone recording permission status.
    var microphoneStatus: Bool { get async }
    /// Request speech recognition authorization from the user.
    func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus
    /// Request microphone recording permission from the user.
    func requestMicrophone() async -> Bool
}

// MARK: - LiveSpeechPermissionChecker

/// Production implementation that calls Apple's Speech and AVFoundation APIs.
public struct LiveSpeechPermissionChecker: SpeechPermissionChecker {
    public var speechStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    public var microphoneStatus: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    public func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    public func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

// MARK: - SpeechAuthorizer

/// Handles the combined Speech Recognition + Microphone permission flow.
///
/// On macOS, speech input requires two separate permissions:
/// 1. **Speech Recognition** (SFSpeechRecognizer) — allows the app to use
///    Apple's on-device speech recognition engine.
/// 2. **Microphone** (AVAudioApplication) — allows the app to capture audio input.
///
/// Both must be granted for voice search to function. This struct provides a
/// single `checkAndRequestPermission()` call that handles both in sequence.
///
/// REQ-3.0-12: Microphone permission prompt and speech authorization.
public struct SpeechAuthorizer: Sendable {

    /// The permission checker used for queries and requests.
    /// Defaults to `LiveSpeechPermissionChecker`; inject a mock for testing.
    private let checker: any SpeechPermissionChecker

    /// Creates an authorizer with the live permission checker.
    public init() {
        self.checker = LiveSpeechPermissionChecker()
    }

    /// Creates an authorizer with a custom permission checker (for testing).
    public init(checker: any SpeechPermissionChecker) {
        self.checker = checker
    }

    // MARK: - Status

    /// The current combined authorization status.
    ///
    /// Returns `.authorized` only when both Speech Recognition and Microphone
    /// permissions are granted. Returns `.denied` if either is denied.
    /// Returns `.restricted` if speech recognition is restricted.
    /// Returns `.notDetermined` if either has not been requested yet.
    public var status: SpeechAuthorizationStatus {
        get async {
            let speech = await checker.speechStatus
            let mic = await checker.microphoneStatus

            switch speech {
            case .authorized:
                return mic ? .authorized : .denied
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                // If speech is not determined, the combined status is not determined
                // regardless of mic state (we can't use speech without speech permission).
                return .notDetermined
            @unknown default:
                return .denied
            }
        }
    }

    // MARK: - Request

    /// Checks current permissions and requests any that are missing.
    ///
    /// Requests Speech Recognition first, then Microphone. If the user grants
    /// both, returns `true`. If either is denied or restricted, returns `false`.
    ///
    /// - Returns: `true` only if both permissions are authorized.
    public func checkAndRequestPermission() async -> Bool {
        // Step 1: Speech Recognition
        let speech = await checker.speechStatus
        let resolvedSpeech: SFSpeechRecognizerAuthorizationStatus

        switch speech {
        case .authorized:
            resolvedSpeech = .authorized
        case .notDetermined:
            resolvedSpeech = await checker.requestSpeech()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }

        guard resolvedSpeech == .authorized else {
            return false
        }

        // Step 2: Microphone
        let micGranted: Bool
        let mic = await checker.microphoneStatus

        if mic {
            micGranted = true
        } else {
            micGranted = await checker.requestMicrophone()
        }

        return micGranted
    }
}
