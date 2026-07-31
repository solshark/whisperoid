import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import WhisperoidCore

/// Owns the dictation state machine and wires the hotkeys to it.
@MainActor
@Observable
final class AppController {

    enum State: Equatable {
        case loading
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    /// Hard ceiling so a forgotten toggle cannot record indefinitely.
    static let maximumRecordingSeconds: Double = 300

    private(set) var state: State = .loading
    private(set) var lastText = ""
    private(set) var lastLanguage = ""
    private(set) var lastDuration: TimeInterval = 0
    private(set) var recordedSeconds: Double = 0
    private(set) var inputLevel: Float = 0

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let injector: any TextInjector = ClipboardInjector()
    private var tickTimer: Timer?

    init() {
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        KeyboardShortcuts.onKeyUp(for: .cancelDictation) { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        }
        KeyboardShortcuts.disable(.cancelDictation)

        Task { await loadModel() }
    }

    // MARK: - Model

    private func loadModel() async {
        do {
            let directory = try Paths.ensureSupportDirectory()
            try await transcriber.load(storageDirectory: directory)
            state = .idle
        } catch {
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Dictation

    func toggle() {
        switch state {
        case .idle, .failed:
            startRecording()
        case .recording:
            finishRecording()
        case .loading, .transcribing:
            NSSound.beep()
        }
    }

    private func startRecording() {
        Task {
            guard await AudioRecorder.requestMicrophoneAccess() else {
                state = .failed("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
                return
            }
            do {
                try recorder.start()
                recordedSeconds = 0
                inputLevel = 0
                state = .recording
                KeyboardShortcuts.enable(.cancelDictation)
                startTicking()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        endRecordingSession()
        state = .idle
    }

    private func finishRecording() {
        guard state == .recording else { return }

        let samples = recorder.stop()
        endRecordingSession()
        state = .transcribing

        Task {
            do {
                let output = try await transcriber.transcribe(samples: samples)
                guard !output.text.isEmpty else {
                    state = .failed("Nothing was transcribed.")
                    return
                }
                try injector.inject(output.text)
                lastText = output.text
                lastLanguage = output.language
                lastDuration = output.duration
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func copyLastAgain() {
        guard !lastText.isEmpty else { return }
        try? injector.inject(lastText)
    }

    private func endRecordingSession() {
        stopTicking()
        KeyboardShortcuts.disable(.cancelDictation)
        recordedSeconds = 0
        inputLevel = 0
    }

    // MARK: - Recording tick

    private func startTicking() {
        stopTicking()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                self.recordedSeconds = self.recorder.recordedSeconds
                self.inputLevel = self.recorder.currentLevel
                if self.recordedSeconds >= Self.maximumRecordingSeconds {
                    self.finishRecording()
                }
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Presentation

    var iconName: String {
        switch state {
        case .loading: "hourglass"
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch state {
        case .loading:
            "Loading model…"
        case .idle:
            lastText.isEmpty
                ? "Ready"
                : String(format: "Ready — last: %@, %.2f s", lastLanguage, lastDuration)
        case .recording:
            String(format: "Recording %.1f s", recordedSeconds)
        case .transcribing:
            "Transcribing…"
        case .failed(let message):
            message
        }
    }

    var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .toggleDictation)
            .map(\.description) ?? "unassigned"
    }
}
