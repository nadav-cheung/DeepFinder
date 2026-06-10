import Testing
import Speech
@testable import DeepFinderAI

@Suite("SpeechAuthorization")
struct SpeechAuthorizationTests {

    // MARK: - SpeechAuthorizationStatus

    @Test("SpeechAuthorizationStatus is Equatable")
    func authorizationStatusEquatable() {
        #expect(SpeechAuthorizationStatus.notDetermined == .notDetermined)
        #expect(SpeechAuthorizationStatus.denied == .denied)
        #expect(SpeechAuthorizationStatus.restricted == .restricted)
        #expect(SpeechAuthorizationStatus.authorized == .authorized)
        #expect(SpeechAuthorizationStatus.notDetermined != .authorized)
        #expect(SpeechAuthorizationStatus.denied != .restricted)
    }

    // MARK: - MockSpeechPermissionChecker

    /// Mock permission checker that stores status in memory for deterministic testing.
    /// `@unchecked Sendable` because mutable properties are only accessed sequentially in tests.
    final class MockSpeechPermissionChecker: SpeechPermissionChecker, @unchecked Sendable {
        nonisolated(unsafe) var speechStatusValue: SFSpeechRecognizerAuthorizationStatus
        nonisolated(unsafe) var microphoneStatusValue: Bool
        nonisolated(unsafe) var requestSpeechResult: SFSpeechRecognizerAuthorizationStatus
        nonisolated(unsafe) var requestMicrophoneResult: Bool

        /// How many times requestSpeech was called.
        nonisolated(unsafe) private(set) var requestSpeechCallCount: Int = 0
        /// How many times requestMicrophone was called.
        nonisolated(unsafe) private(set) var requestMicrophoneCallCount: Int = 0

        init(
            speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined,
            microphoneStatus: Bool = false,
            requestSpeechResult: SFSpeechRecognizerAuthorizationStatus = .authorized,
            requestMicrophoneResult: Bool = true
        ) {
            self.speechStatusValue = speechStatus
            self.microphoneStatusValue = microphoneStatus
            self.requestSpeechResult = requestSpeechResult
            self.requestMicrophoneResult = requestMicrophoneResult
        }

        var speechStatus: SFSpeechRecognizerAuthorizationStatus {
            speechStatusValue
        }

        var microphoneStatus: Bool {
            microphoneStatusValue
        }

        func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
            requestSpeechCallCount += 1
            return requestSpeechResult
        }

        func requestMicrophone() async -> Bool {
            requestMicrophoneCallCount += 1
            return requestMicrophoneResult
        }
    }

    // MARK: - checkAndRequestPermission

    @Test("checkAndRequestPermission returns true when both already granted")
    func bothAlreadyGranted() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .authorized,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == true)
        #expect(checker.requestSpeechCallCount == 0)
        #expect(checker.requestMicrophoneCallCount == 0)
    }

    @Test("checkAndRequestPermission requests speech when not determined")
    func requestsSpeechWhenNotDetermined() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .notDetermined,
            microphoneStatus: true,
            requestSpeechResult: .authorized
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == true)
        #expect(checker.requestSpeechCallCount == 1)
    }

    @Test("checkAndRequestPermission requests microphone when not granted")
    func requestsMicrophoneWhenNotGranted() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .authorized,
            microphoneStatus: false,
            requestMicrophoneResult: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == true)
        #expect(checker.requestMicrophoneCallCount == 1)
    }

    @Test("checkAndRequestPermission returns false when speech denied")
    func returnsFalseWhenSpeechDenied() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .denied,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == false)
    }

    @Test("checkAndRequestPermission returns false when speech restricted")
    func returnsFalseWhenSpeechRestricted() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .restricted,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == false)
    }

    @Test("checkAndRequestPermission returns false when speech request denied")
    func returnsFalseWhenSpeechRequestDenied() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .notDetermined,
            requestSpeechResult: .denied
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == false)
    }

    @Test("checkAndRequestPermission returns false when microphone denied")
    func returnsFalseWhenMicrophoneDenied() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .authorized,
            microphoneStatus: false,
            requestMicrophoneResult: false
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == false)
    }

    @Test("checkAndRequestPermission requests both when neither determined")
    func requestsBothWhenNeitherDetermined() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .notDetermined,
            microphoneStatus: false,
            requestSpeechResult: .authorized,
            requestMicrophoneResult: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let result = await authorizer.checkAndRequestPermission()
        #expect(result == true)
        #expect(checker.requestSpeechCallCount == 1)
        #expect(checker.requestMicrophoneCallCount == 1)
    }

    // MARK: - status property

    @Test("status returns authorized when both granted")
    func statusAuthorized() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .authorized,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let status = await authorizer.status
        #expect(status == .authorized)
    }

    @Test("status returns denied when speech authorized but mic denied")
    func statusDeniedWhenMicDenied() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .authorized,
            microphoneStatus: false
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let status = await authorizer.status
        #expect(status == .denied)
    }

    @Test("status returns denied when speech denied")
    func statusDeniedWhenSpeechDenied() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .denied,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let status = await authorizer.status
        #expect(status == .denied)
    }

    @Test("status returns restricted when speech restricted")
    func statusRestricted() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .restricted,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let status = await authorizer.status
        #expect(status == .restricted)
    }

    @Test("status returns notDetermined when speech not determined")
    func statusNotDetermined() async {
        let checker = MockSpeechPermissionChecker(
            speechStatus: .notDetermined,
            microphoneStatus: true
        )
        let authorizer = SpeechAuthorizer(checker: checker)
        let status = await authorizer.status
        #expect(status == .notDetermined)
    }
}
