// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - SpeechOverlayActions

/// Protocol defining actions the speech overlay can trigger.
///
/// Extracted for testability: production passes a real view model,
/// tests pass a mock that records calls.
public protocol SpeechOverlayActions: AnyObject, Sendable {
    /// Called when the user's speech has been finalized and a search should execute.
    func triggerSearch(_ query: String) async
    /// Called when the overlay is dismissed (cancel or completion).
    func dismissOverlay()
}

// MARK: - SpeechOverlayViewModel

/// View model driving the speech overlay UI.
///
/// Manages the streaming transcript from `LocalSpeechProvider`,
/// displays real-time partial results, and auto-triggers search
/// when the speech recognizer emits a final result.
///
/// REQ-3.0-12: Speech overlay with real-time transcript and auto-trigger.
@MainActor
@Observable
final class SpeechOverlayViewModel {

    // MARK: - State

    /// The current (possibly partial) transcript text displayed in the overlay.
    private(set) var transcript: String = ""

    /// Whether the overlay is actively listening for speech input.
    private(set) var isListening: Bool = false

    /// Whether the overlay is visible.
    private(set) var isVisible: Bool = false

    /// Animation phase for the waveform indicator (0.0...1.0, cycles continuously).
    private(set) var waveformPhase: Double = 0

    // MARK: - Dependencies

    /// The speech provider that streams recognition results.
    private let speechProvider: any SpeechRecognizerProtocol

    /// Actions to invoke on speech events (search trigger, dismiss).
    private let actions: any SpeechOverlayActions

    /// Task holding the active listening stream consumption.
    private var listeningTask: Task<Void, Never>?

    /// Timer driving the waveform animation.
    private var waveformTimer: Timer?

    // MARK: - Init

    /// Creates the view model with the given speech provider and action handler.
    ///
    /// - Parameters:
    ///   - speechProvider: Provides the stream of speech recognition results.
    ///   - actions: Handles search triggers and overlay dismissal.
    public init(
        speechProvider: any SpeechRecognizerProtocol,
        actions: any SpeechOverlayActions
    ) {
        self.speechProvider = speechProvider
        self.actions = actions
    }

    // MARK: - Lifecycle

    /// Shows the overlay and starts listening for speech input.
    public func startListening() {
        guard !isListening else { return }

        isVisible = true
        transcript = ""
        isListening = true
        startWaveformAnimation()

        listeningTask = Task { [speechProvider] in
            guard let stream = speechProvider.startRecognition() else {
                // Speech recognition unavailable — dismiss.
                stopAndDismiss()
                return
            }

            for await result in stream {
                guard !Task.isCancelled else { return }

                transcript = result.text

                if result.isFinal {
                    // Auto-trigger search after the Speech framework detects
                    // silence (~1.5 s, per LocalSpeechProvider.speechAutoTriggerInterval).
                    let query = result.text
                    stopAndDismiss()
                    await actions.triggerSearch(query)
                    return
                }
            }

            // Stream ended without a final result (e.g., no speech detected).
            stopAndDismiss()
        }
    }

    /// Cancels speech input and dismisses the overlay.
    public func cancel() {
        listeningTask?.cancel()
        listeningTask = nil

        Task { [speechProvider] in
            await speechProvider.stopRecognition()
        }

        stopWaveformAnimation()
        isListening = false
        isVisible = false
        transcript = ""
        actions.dismissOverlay()
    }

    // MARK: - Private

    /// Stops listening and dismisses the overlay (internal cleanup).
    private func stopAndDismiss() {
        listeningTask?.cancel()
        listeningTask = nil

        Task { [speechProvider] in
            await speechProvider.stopRecognition()
        }

        stopWaveformAnimation()
        isListening = false
        isVisible = false
    }

    /// Starts a repeating timer that advances the waveform animation phase.
    private func startWaveformAnimation() {
        stopWaveformAnimation()
        waveformPhase = 0

        waveformTimer = Timer.scheduledTimer(
            withTimeInterval: 0.03, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.waveformPhase = (self?.waveformPhase ?? 0) + 0.05
                if (self?.waveformPhase ?? 0) > 1.0 {
                    self?.waveformPhase = 0
                }
            }
        }
    }

    /// Stops the waveform animation timer.
    private func stopWaveformAnimation() {
        waveformTimer?.invalidate()
        waveformTimer = nil
    }
}

// MARK: - SpeechOverlayView

/// A small floating overlay shown during voice input.
///
/// Displays:
/// - An animated waveform indicator while listening
/// - Real-time transcript text streamed from the speech recognizer
/// - A cancel button to dismiss without triggering a search
///
/// Auto-triggers search when the speech recognizer finalizes the utterance
/// (after ~1.5 s of silence, per LocalSpeechProvider.speechAutoTriggerInterval).
///
/// REQ-3.0-12: Speech overlay GUI component.
public struct SpeechOverlayView: View {

    @Bindable var viewModel: SpeechOverlayViewModel

    @State private var isCancelHovered = false

    public var body: some View {
        VStack(spacing: 12) {
            // Waveform indicator
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    WaveformBar(phase: viewModel.waveformPhase, index: index)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [
                                GlowColors.teal.opacity(0.08),
                                GlowColors.violet.opacity(0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .blur(radius: 6)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            )
            .frame(height: 24)
            .opacity(viewModel.isListening ? 1 : 0.3)

            // Transcript
            Text(viewModel.transcript.isEmpty ? "正在聆听..." : viewModel.transcript)
                .font(.system(size: 15))
                .foregroundStyle(viewModel.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .animation(.spring(duration: 0.3, bounce: 0.2), value: viewModel.transcript)

            // Cancel button
            Button {
                viewModel.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
                    .scaleEffect(isCancelHovered ? 1.15 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消语音输入")
            .onHover { hovering in
                withAnimation(.spring(duration: 0.25, bounce: 0.3)) {
                    isCancelHovered = hovering
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .frame(minWidth: 200, maxWidth: 300)
    }
}

// MARK: - WaveformBar

/// A single animated bar in the waveform visualization.
///
/// Each bar oscillates in height based on the animation phase and its
/// position index, creating a staggered wave effect.
private struct WaveformBar: View {
    public let phase: Double
    public let index: Int

    /// Computes a pseudo-random height based on phase and index.
    private var barHeight: CGFloat {
        let offset = Double(index) * 0.2
        let wave = sin((phase + offset) * .pi * 2)
        return 6 + abs(wave) * 18
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [GlowColors.teal, GlowColors.violet],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: 4, height: barHeight)
            .animation(.spring(duration: 0.12, bounce: 0.4), value: phase)
    }
}
