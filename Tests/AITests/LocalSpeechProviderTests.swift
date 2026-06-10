// Tests/AITests/LocalSpeechProviderTests.swift
import Testing
import Foundation
import Speech
@testable import DeepFinderAI

@Suite("LocalSpeechProvider")
struct LocalSpeechProviderTests {

    // MARK: - SpeechRecognitionResult

    @Test("SpeechRecognitionResult holds text and isFinal")
    func speechRecognitionResultProperties() {
        let partial = SpeechRecognitionResult(text: "hello", isFinal: false)
        #expect(partial.text == "hello")
        #expect(partial.isFinal == false)

        let final = SpeechRecognitionResult(text: "hello world", isFinal: true)
        #expect(final.text == "hello world")
        #expect(final.isFinal == true)
    }

    @Test("SpeechRecognitionResult is Equatable")
    func speechRecognitionResultEquatable() {
        let a = SpeechRecognitionResult(text: "test", isFinal: false)
        let b = SpeechRecognitionResult(text: "test", isFinal: false)
        let c = SpeechRecognitionResult(text: "other", isFinal: true)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Supported Locales

    @Test("Speech framework supports en-US and zh-CN locales")
    func supportedLocalesIncludesEnUsAndZhCn() {
        // This tests that the system Speech framework has on-device models
        // for both English (US) and Chinese (Simplified).
        // Locale.identifier uses hyphens (e.g. "en-US", "zh-CN").
        let locales = SFSpeechRecognizer.supportedLocales()
        #expect(locales.contains(where: { $0.identifier == "en-US" }))
        #expect(locales.contains(where: { $0.identifier == "zh-CN" }))
    }

    // MARK: - isAvailable

    @Test("isAvailable returns a boolean without crashing")
    func isAvailableReturnsBool() async {
        // We cannot assert a specific value since speech recognition
        // availability depends on the runtime environment, but we can
        // verify the call completes without error.
        let available = await LocalSpeechProvider.isAvailable()
        // On macOS CI runners without speech recognition, this may be false.
        // On a real Mac it should be true. Just verify it doesn't crash.
        _ = available
    }

    // MARK: - startListening returns nil when speech unavailable

    @Test("startListening returns nil when recognizer is unavailable")
    func startListeningReturnsNilWhenUnavailable() async {
        // Create a provider with a locale that is unlikely to have
        // an on-device model, forcing the unavailable path.
        let provider = await LocalSpeechProvider(locale: Locale(identifier: "xx_XX"))
        let stream = await provider.startListening()
        #expect(stream == nil)
    }

    // MARK: - Listening state

    @Test("isListening is false initially")
    func isListeningFalseInitially() async {
        let provider = LocalSpeechProvider()
        let listening = await provider.isListening
        #expect(listening == false)
    }

    @Test("stopListening resets isListening to false")
    func stopListeningResetsState() async {
        let provider = LocalSpeechProvider()
        await provider.stopListening()
        let listening = await provider.isListening
        #expect(listening == false)
    }

    // MARK: - Mock injection for transcribe testing

    @Test("transcribe returns injected mock result")
    func transcribeReturnsMockResult() async {
        let mockResult = SpeechRecognitionResult(text: "找上个月的合同", isFinal: true)
        let provider = LocalSpeechProvider(mockResults: [mockResult])
        let result = await provider.transcribe()
        #expect(result == mockResult)
    }

    @Test("transcribe returns nil when no mock results")
    func transcribeReturnsNilWhenNoResults() async {
        let provider = LocalSpeechProvider(mockResults: [])
        let result = await provider.transcribe()
        #expect(result == nil)
    }

    // MARK: - Speech auto-trigger interval (REQ-3.0-12)

    @Test("speechAutoTriggerInterval is 1.5 seconds")
    func speechAutoTriggerInterval() {
        #expect(LocalSpeechProvider.speechAutoTriggerInterval == 1.5)
    }

    @Test("transcribe streams multiple mock results sequentially")
    func transcribeStreamsMultipleResults() async {
        let results = [
            SpeechRecognitionResult(text: "hello", isFinal: false),
            SpeechRecognitionResult(text: "hello world", isFinal: false),
            SpeechRecognitionResult(text: "hello world test", isFinal: true),
        ]
        let provider = LocalSpeechProvider(mockResults: results)

        var collected: [SpeechRecognitionResult] = []
        for await result in provider.transcribeStream() {
            collected.append(result)
        }

        #expect(collected == results)
    }
}
