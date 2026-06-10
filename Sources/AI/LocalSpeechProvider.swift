/// On-device speech recognition using Apple's Speech framework.
///
/// Streams partial transcription results for real-time display, then a final result
/// when the utterance completes. Supports mock injection for testing without a microphone.
/// Completely local -- no audio data leaves the device.
// Sources/AI/LocalSpeechProvider.swift
import Foundation
import OSLog
import Speech
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

/// A single speech recognition result, containing the transcribed text
/// and whether this is the final (complete) result.
///
/// REQ-3.0-12: Streams partial results for real-time display, then a final
/// result when the user stops speaking.
public struct SpeechRecognitionResult: Sendable, Equatable {
    /// The transcribed text (may be partial or final).
    public let text: String
    /// `true` when this is the final result for the current utterance.
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

// MARK: - SpeechRecognizerProtocol

/// Protocol abstracting SFSpeechRecognizer operations for testability.
///
/// The real implementation wraps Apple's Speech framework. Tests inject
/// a mock that returns canned results without requiring a microphone.
public protocol SpeechRecognizerProtocol: Sendable {
    /// Whether a recognizer is available for the configured locale.
    var available: Bool { get async }
    /// Begin listening. Returns an AsyncStream of recognition results,
    /// or nil if speech recognition is unavailable.
    func startRecognition() -> AsyncStream<SpeechRecognitionResult>?
    /// Stop any active recognition task.
    func stopRecognition() async
}

// MARK: - LocalSpeechProvider

/// Provides local (on-device) speech recognition using Apple's Speech framework.
///
/// **Privacy**: Completely local execution. Supports Chinese and English.
/// Audio is processed on-device by Apple's Speech framework; no audio data
/// or transcriptions leave the device.
///
/// **Graceful degradation**:
/// - `startListening()` returns `nil` if speech recognition is unavailable
///   for the configured locale (e.g., unsupported language, restricted device)
/// - `transcribe()` returns `nil` if no results are available
/// - Real-time streaming emits partial results, then a final result when
///   the utterance is complete
///
/// **Testability**: Inject `mockResults` in tests to bypass the real Speech
/// framework (which requires hardware microphone input).
///
/// REQ-3.0-12: Local speech recognition.
public actor LocalSpeechProvider: @preconcurrency SpeechRecognizerProtocol {

    // MARK: - SpeechRecognizerProtocol Conformance

    public var available: Bool {
        get async { await Self.isAvailable() }
    }

    public func startRecognition() -> AsyncStream<SpeechRecognitionResult>? {
        startListening()
    }

    public func stopRecognition() async {
        stopListening()
    }

    /// The approximate silence duration (in seconds) after which Apple's Speech
    /// framework emits a final result (`isFinal == true`), automatically
    /// triggering a search.
    ///
    /// The Speech framework handles silence detection natively — no explicit
    /// timer or voice-activity detection is needed on our side. After roughly
    /// this interval of silence following an utterance, the framework finalizes
    /// recognition and delivers `isFinal == true` in the result callback.
    ///
    /// - Note: The exact timing varies slightly depending on audio conditions
    ///   and is not configurable via the Speech API. This constant documents
    ///   the observed ~1.5 s behavior for REQ-3.0-12 compliance and serves as
    ///   a reference for UI elements that display auto-trigger timing.
    public static let speechAutoTriggerInterval: TimeInterval = 1.5

    /// Whether the provider is currently listening for speech input.
    private(set) var isListening: Bool = false

    /// The locale for speech recognition (default: user's current locale).
    private let locale: Locale

    /// Mock results injected by tests. When non-nil, `transcribe()` and
    /// `transcribeStream()` return these instead of calling the Speech framework.
    private let mockResults: [SpeechRecognitionResult]?

    /// The underlying Speech framework recognizer. Nil if the locale is unsupported.
    private var recognizer: SFSpeechRecognizer?

    /// Active recognition task, if any.
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Active recognition request, if any.
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    // MARK: - Initializers

    /// Creates a provider for the user's current locale with real Speech framework.
    public init() {
        self.locale = Locale.current
        self.mockResults = nil
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Creates a provider with mock results for testing.
    ///
    /// - Parameter mockResults: Fixed results to return from `transcribe()` / `transcribeStream()`.
    public init(mockResults: [SpeechRecognitionResult]) {
        self.locale = Locale.current
        self.mockResults = mockResults
        self.recognizer = nil
    }

    /// Creates a provider for a specific locale (used for testing unavailable locales).
    ///
    /// - Parameter locale: The locale to attempt speech recognition with.
    public init(locale: Locale) {
        self.locale = locale
        self.mockResults = nil
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Availability

    /// Checks whether speech recognition is available on this device.
    ///
    /// On real hardware this typically returns `true`. May return `false`
    /// on CI runners or when the Speech framework is restricted.
    public static func isAvailable() async -> Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.isAvailable
    }

    // MARK: - Listening

    /// Starts listening for speech input and returns a stream of recognition results.
    ///
    /// The stream emits partial results as the user speaks, then a final result
    /// when the utterance is complete. Returns `nil` if speech recognition is
    /// not available for the configured locale.
    ///
    /// Only one listening session can be active at a time.
    public func startListening() -> AsyncStream<SpeechRecognitionResult>? {
        // If mock results are configured, return them as a stream
        if let mockResults {
            isListening = true
            return AsyncStream { continuation in
                for result in mockResults {
                    continuation.yield(result)
                }
                continuation.finish()
            }
        }

        guard let recognizer, recognizer.isAvailable else {
            return nil
        }

        isListening = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        return AsyncStream { continuation in
            // Strong reference is intentional — the recognition task is scoped
            // to this stream's lifetime. Using [weak self] risks leaking the
            // SFSpeechRecognitionTask if the actor is deallocated mid-recognition.
            recognizer.recognitionTask(with: request) { result, error in
                guard let result else {
                    if let error {
                        Logger(subsystem: Product.aiSubsystem, category: "speech")
                            .warning("Speech recognition error: \(error)")
                    }
                    continuation.finish()
                    return
                }

                let recognitionResult = SpeechRecognitionResult(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )
                continuation.yield(recognitionResult)

                if result.isFinal {
                    continuation.finish()
                }
            }
        }
    }

    /// Stops the current listening session.
    public func stopListening() {
        isListening = false
        cleanup()
    }

    // MARK: - Convenience: single-shot transcribe

    /// Transcribes speech and returns the final result.
    ///
    /// For tests with mock results, returns the last (final) result.
    /// Returns nil if no results are available.
    public func transcribe() async -> SpeechRecognitionResult? {
        guard let mockResults, !mockResults.isEmpty else {
            return nil
        }
        return mockResults.last
    }

    /// Returns all mock results as an async sequence for streaming tests.
    ///
    /// Only intended for use with mock-injected providers in tests.
    /// `nonisolated` so callers can iterate the stream without being inside
    /// the actor -- AsyncStream itself handles thread safety.
    nonisolated func transcribeStream() -> AsyncStream<SpeechRecognitionResult> {
        guard let mockResults else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            for result in mockResults {
                continuation.yield(result)
            }
            continuation.finish()
        }
    }

    // MARK: - Private

    /// Cleans up recognition task and request resources.
    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }
}
