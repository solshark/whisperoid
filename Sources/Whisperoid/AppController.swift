import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import WhisperoidCore

struct Transcription: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let language: String
    let duration: TimeInterval
}

/// Owns the dictation state machine and wires the hotkeys and overlay to it.
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

    /// How many past transcriptions stay available in the menu. The clipboard
    /// is clobbered by every dictation, so this is the safety net.
    static let historyLimit = 10

    private static let waveformInterval: TimeInterval = 1.0 / 30.0
    private static let successDismissDelay: Double = 3.0
    private static let failureDismissDelay: Double = 4.5

    private(set) var state: State = .loading
    private(set) var recordedSeconds: Double = 0
    private(set) var history: [Transcription] = []
    private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    private(set) var launchAtLoginMessage: String?

    let preferences = Preferences()

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let injector: any TextInjector = ClipboardInjector()
    private let overlay = OverlayController()
    private var tickTimer: Timer?
    private var silenceDetector: SilenceDetector?

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
        let started = Date()
        do {
            let directory = try Paths.ensureSupportDirectory()
            log("loading \(Transcriber.modelVariant) from \(directory.path)")
            try await transcriber.load(storageDirectory: directory)
            log(String(format: "model ready in %.2f s", Date().timeIntervalSince(started)))
            state = .idle
        } catch {
            log("model load failed: \(error)")
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("whisperoid: \(message)\n".utf8))
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
                fail("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
                return
            }
            do {
                try recorder.start()
                recordedSeconds = 0
                state = .recording

                silenceDetector = preferences.autoStopOnSilence
                    ? SilenceDetector(requiredSilence: preferences.silenceSeconds)
                    : nil

                overlay.model.levels = []
                overlay.model.elapsed = 0
                overlay.present(.recording)

                if preferences.playSounds { Sounds.playStart() }

                KeyboardShortcuts.enable(.cancelDictation)
                startTicking()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        endRecordingSession()
        overlay.hideImmediately()
        state = .idle
    }

    private func finishRecording() {
        guard state == .recording else { return }

        let samples = recorder.stop()
        endRecordingSession()
        state = .transcribing
        overlay.update(.transcribing)

        Task {
            do {
                let output = try await transcriber.transcribe(samples: samples)
                guard !output.text.isEmpty else {
                    fail("Nothing was transcribed.")
                    return
                }

                try injector.inject(output.text)
                record(output)

                overlay.model.text = output.text
                overlay.model.language = output.language
                overlay.model.duration = output.duration
                overlay.update(.done)
                overlay.dismiss(after: Self.successDismissDelay)

                if preferences.playSounds { Sounds.playFinished() }

                state = .idle
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func record(_ output: Transcriber.Output) {
        history.insert(
            Transcription(
                text: output.text,
                language: output.language,
                duration: output.duration
            ),
            at: 0
        )
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        overlay.model.message = message
        overlay.update(.failed)
        overlay.dismiss(after: Self.failureDismissDelay)
        if preferences.playSounds { Sounds.playFailed() }
    }

    func copy(_ transcription: Transcription) {
        try? injector.inject(transcription.text)
    }

    func copyLastAgain() {
        guard let latest = history.first else { return }
        copy(latest)
    }

    func clearHistory() {
        history.removeAll()
    }

    private func endRecordingSession() {
        stopTicking()
        silenceDetector = nil
        KeyboardShortcuts.disable(.cancelDictation)
        recordedSeconds = 0
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLoginMessage = LaunchAtLogin.requiresUserApproval
                ? "Approval is needed in System Settings > General > Login Items."
                : nil
        } catch {
            launchAtLoginMessage = error.localizedDescription
        }
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    // MARK: - Recording tick

    private func startTicking() {
        stopTicking()

        let timer = Timer(timeInterval: Self.waveformInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }

                self.recordedSeconds = self.recorder.recordedSeconds
                self.overlay.model.levels = self.recorder.recentLevels
                self.overlay.model.elapsed = self.recordedSeconds

                if self.recordedSeconds >= Self.maximumRecordingSeconds {
                    self.finishRecording()
                    return
                }
                if self.silenceDetector?.update(level: self.recorder.currentLevel) == true {
                    self.finishRecording()
                }
            }
        }
        // Common mode keeps the waveform animating while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
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
            history.first.map {
                String(format: "Ready — last: %@, %.2f s", $0.language, $0.duration)
            } ?? "Ready"
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
