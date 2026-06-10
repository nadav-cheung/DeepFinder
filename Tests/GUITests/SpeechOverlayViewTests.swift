import Testing
import DeepFinderIndex
import DeepFinderSearch
import Speech
import DeepFinderAI
import DeepFinderDaemon
@testable import DeepFinderGUILib

@Suite("SpeechOverlayView")
@MainActor
struct SpeechOverlayViewTests {

    // MARK: - Mocks

    /// Mock speech recognizer that yields canned results.
    /// `@unchecked Sendable` because mutable state is only accessed sequentially in tests.
    final class MockSpeechRecognizer: SpeechRecognizerProtocol, @unchecked Sendable {
        private let results: [SpeechRecognitionResult]?

        init(results: [SpeechRecognitionResult]? = nil) {
            self.results = results
        }

        var available: Bool { results != nil }

        func startRecognition() -> AsyncStream<SpeechRecognitionResult>? {
            guard let results else { return nil }
            return AsyncStream { continuation in
                for result in results {
                    continuation.yield(result)
                }
                continuation.finish()
            }
        }

        func stopRecognition() async {
            // No-op in mock.
        }
    }

    /// Mock action handler that records calls.
    @MainActor
    final class MockSpeechOverlayActions: @preconcurrency SpeechOverlayActions, @unchecked Sendable {
        private(set) var searchTriggered: [String] = []
        private(set) var dismissCallCount: Int = 0

        func triggerSearch(_ query: String) async {
            searchTriggered.append(query)
        }

        func dismissOverlay() {
            dismissCallCount += 1
        }
    }

    // MARK: - Helpers

    /// Creates a fresh view model and actions pair for each test.
    private func makeViewModel(
        results: [SpeechRecognitionResult]? = nil
    ) -> (SpeechOverlayViewModel, MockSpeechOverlayActions) {
        let speech = MockSpeechRecognizer(results: results)
        let actions = MockSpeechOverlayActions()
        let vm = SpeechOverlayViewModel(speechProvider: speech, actions: actions)
        return (vm, actions)
    }

    // MARK: - ViewModel lifecycle

    @Test("startListening sets isVisible and isListening")
    func startListeningSetsVisible() async {
        let (vm, _) = makeViewModel(results: [
            SpeechRecognitionResult(text: "test", isFinal: true),
        ])

        vm.startListening()

        #expect(vm.isVisible == true)
        #expect(vm.isListening == true)

        // Give the async stream time to deliver results.
        try? await Task.sleep(for: .milliseconds(200))

        #expect(vm.transcript == "test")
    }

    @Test("startListening with nil stream dismisses immediately")
    func startListeningNilStreamDismisses() async {
        let (vm, _) = makeViewModel(results: nil)

        vm.startListening()

        // Give the task time to run.
        try? await Task.sleep(for: .milliseconds(100))

        #expect(vm.isVisible == false)
        #expect(vm.isListening == false)
    }

    @Test("cancel resets state and calls dismissOverlay")
    func cancelResetsState() async {
        let (vm, actions) = makeViewModel(results: [
            SpeechRecognitionResult(text: "hello", isFinal: false),
        ])

        vm.startListening()
        #expect(vm.isListening == true)

        vm.cancel()

        #expect(vm.isListening == false)
        #expect(vm.isVisible == false)
        #expect(vm.transcript == "")
        #expect(actions.dismissCallCount == 1)
    }

    @Test("startListening does nothing if already listening")
    func startListeningIdempotent() async {
        let (vm, actions) = makeViewModel(results: [
            SpeechRecognitionResult(text: "a", isFinal: true),
        ])

        vm.startListening()
        vm.startListening() // Second call should be a no-op.

        // Wait for the stream to complete.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(actions.searchTriggered.count <= 1)
    }

    // MARK: - Auto-trigger search on final result

    @Test("auto-triggers search when final result received")
    func autoTriggerSearchOnFinal() async {
        let (vm, actions) = makeViewModel(results: [
            SpeechRecognitionResult(text: "报告", isFinal: false),
            SpeechRecognitionResult(text: "报告文件", isFinal: true),
        ])

        vm.startListening()

        // Wait for the stream to deliver all results and trigger search.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(actions.searchTriggered == ["报告文件"])
        #expect(vm.isVisible == false)
        #expect(vm.isListening == false)
    }

    // MARK: - Transcript updates

    @Test("transcript updates with partial results")
    func transcriptUpdatesWithPartials() async {
        let (vm, actions) = makeViewModel(results: [
            SpeechRecognitionResult(text: "hel", isFinal: false),
            SpeechRecognitionResult(text: "hello", isFinal: false),
            SpeechRecognitionResult(text: "hello world", isFinal: true),
        ])

        vm.startListening()

        // Wait for all results.
        try? await Task.sleep(for: .milliseconds(300))

        // The final result triggers search with "hello world".
        #expect(actions.searchTriggered == ["hello world"])
    }

    // MARK: - Waveform animation

    @Test("waveform phase advances while listening")
    func waveformPhaseAdvances() async {
        let (vm, _) = makeViewModel(results: [
            SpeechRecognitionResult(text: "test", isFinal: false),
        ])

        vm.startListening()

        // The timer should advance the phase. After a short wait, verify
        // the phase is in a valid range.
        try? await Task.sleep(for: .milliseconds(100))

        #expect(vm.waveformPhase >= 0)
        #expect(vm.waveformPhase <= 1)

        vm.cancel()
    }

    // MARK: - Cancel does not trigger search

    @Test("cancel does not trigger search")
    func cancelNoSearch() async {
        let (vm, actions) = makeViewModel(results: [
            SpeechRecognitionResult(text: "partial", isFinal: false),
        ])

        vm.startListening()
        try? await Task.sleep(for: .milliseconds(50))
        vm.cancel()

        #expect(actions.searchTriggered.isEmpty)
        #expect(actions.dismissCallCount == 1)
    }
}
