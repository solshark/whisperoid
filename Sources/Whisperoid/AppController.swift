import AppKit
import Foundation
import Observation
import WhisperoidCore

struct Transcription: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let language: String
    let duration: TimeInterval
    /// What the transcriber produced before cleanup, when cleanup changed it.
    /// Kept so a cleanup can be judged against what it replaced instead of
    /// being taken on trust.
    var originalText: String?
    var cleanupSeconds: TimeInterval?
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

    /// How long a startup phase may go without changing before the status says
    /// so. Core ML preparation legitimately takes minutes on a machine that has
    /// not compiled this model before, so this reports rather than fails.
    private static let stallWarningSeconds: TimeInterval = 45

    private(set) var state: State = .loading
    private(set) var recordedSeconds: Double = 0
    private(set) var history: [Transcription] = []
    private(set) var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    private(set) var launchAtLoginMessage: String?

    private(set) var loadPhase: Transcriber.Phase = .locating
    /// Progress of the optional cleanup model, shown in Settings. Its first
    /// load downloads several gigabytes, which must be visible rather than
    /// looking like the app has hung.
    private(set) var cleanupPhase: EmbeddedCleaner.Phase = .idle
    private(set) var lastErrorText: String?
    private var phaseChangedAt = Date()
    private var loggedDownloadPercent = -1
    private var downloadedBytes: Int64 = 0
    private var watchdog: Timer?

    let preferences = Preferences()

    private let recorder = AudioRecorder()

    /// True between the shortcut being pressed and the engine actually running.
    ///
    /// Starting the engine is asynchronous and can take a noticeable moment, so
    /// unlike before there is a window in which the main thread is free, `state`
    /// is still `.idle`, and the shortcut can be pressed again.
    private var isStartingRecording = false
    private let transcriber = Transcriber()
    private let injector: any TextInjector = ClipboardInjector()
    private let overlay = OverlayController()
    @ObservationIgnored private var settingsWindow: HostedWindowController<SettingsView>?
    @ObservationIgnored private var aboutWindow: HostedWindowController<AboutView>?
    @ObservationIgnored private var acknowledgementsWindow: HostedWindowController<AcknowledgementsView>?
    private var tickTimer: Timer?
    private var silenceDetector: SilenceDetector?
    /// Nil only when the support directory cannot be created, in which case
    /// cleanup is unavailable and dictation continues without it.
    private let embeddedCleaner: EmbeddedCleaner?
    @ObservationIgnored private var cleanupUnloadTimer: Timer?

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = HostedWindowController(
                title: "Whisperoid Settings",
                diagnosticName: "settings"
            ) { [unowned self] in
                SettingsView(controller: self, preferences: self.preferences)
            }
        }
        settingsWindow?.show()
    }

    func showAbout() {
        if aboutWindow == nil {
            aboutWindow = HostedWindowController(
                title: "About Whisperoid",
                diagnosticName: "about"
            ) { [unowned self] in
                AboutView(onShowAcknowledgements: { self.showAcknowledgements() })
            }
        }
        aboutWindow?.show()
    }

    func showAcknowledgements() {
        if acknowledgementsWindow == nil {
            acknowledgementsWindow = HostedWindowController(
                title: "Acknowledgements",
                diagnosticName: "acknowledgements",
                isResizable: true
            ) {
                AcknowledgementsView()
            }
        }
        acknowledgementsWindow?.show()
    }

    init() {
        embeddedCleaner = (try? Paths.ensureSupportDirectory()).map {
            EmbeddedCleaner(storageDirectory: $0)
        }

        HotkeyCenter.shared.onKeyUp(for: .toggleDictation) { [weak self] in
            self?.toggle()
        }
        HotkeyCenter.shared.onKeyUp(for: .cancelDictation) { [weak self] in
            self?.cancel()
        }
        HotkeyCenter.shared.setEnabled(false, for: .cancelDictation)
        Log.info("hotkey: toggle=\(shortcutDescription)")

        // Connecting or removing an input device invalidates the format the tap
        // was installed with. Finish with whatever was captured rather than keep
        // recording audio that cannot be trusted.
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.handleAudioConfigurationChange() }
        }

        // Diagnostic hooks: open a window shortly after launch so it can be
        // verified without driving the menu bar.
        let environment = ProcessInfo.processInfo.environment
        if environment["WHISPEROID_SHOW_SETTINGS"] != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                showSettings()
            }
        }
        if environment["WHISPEROID_SHOW_ACKNOWLEDGEMENTS"] != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                showAcknowledgements()
            }
        }
        if environment["WHISPEROID_SHOW_ABOUT"] != nil {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                showAbout()
            }
        }

        Task {
            await loadModel()
            if ProcessInfo.processInfo.environment["WHISPEROID_DUMP_DIAGNOSTICS"] != nil {
                logDiagnostics()
            }
        }
    }

    // MARK: - Model

    private func loadModel() async {
        let started = Date()
        startWatchdog()
        defer { stopWatchdog() }

        do {
            let directory = try Paths.ensureSupportDirectory()
            Log.info("startup: variant=\(Transcriber.modelVariant) storage=\(directory.path)")
            Log.info("startup: model folder \(Transcriber.modelFolder(in: directory).path)")
            Log.info(Transcriber.localModel(in: directory) != nil
                ? "startup: model already on disk, skipping network"
                : "startup: model not cached, will download")

            try await transcriber.load(storageDirectory: directory) { [weak self] phase in
                Task { @MainActor in self?.apply(phase) }
            }

            Log.info(String(format: "startup: ready in %.2f s", Date().timeIntervalSince(started)))
            lastErrorText = nil
            state = .idle

            // Warm the cleanup model when it is already the chosen mode, so the
            // first dictation of a session is not the one that pays for the
            // load. The idle timer starts with it, so an unused model does not
            // sit on several gigabytes indefinitely.
            prepareCleanupModel()
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            Log.error(String(format: "startup: failed after %.2f s during %@: %@",
                             elapsed, loadPhase.description, String(describing: error)))
            lastErrorText = "\(error)"
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ phase: Transcriber.Phase) {
        loadPhase = phase
        phaseChangedAt = Date()

        switch phase {
        case .downloading(let fraction, let completedFiles, let totalFiles):
            // Progress fires constantly; log only on each whole percent so the
            // unified log stays readable but a stall is still visible.
            let percent = Int(fraction * 100)
            if percent != loggedDownloadPercent {
                loggedDownloadPercent = percent
                Log.info("startup: downloading \(percent)% (file \(completedFiles) of \(totalFiles))")
            }
        default:
            Log.info("startup: \(phase.description)")
        }
    }

    /// Reports a phase that has not advanced. Startup can legitimately be slow,
    /// so this never cancels anything; it only makes the wait explicable.
    private func startWatchdog() {
        stopWatchdog()
        phaseChangedAt = Date()

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .loading else { return }
                self.measureDownloadedBytes()

                let stalled = Date().timeIntervalSince(self.phaseChangedAt)
                guard stalled >= Self.stallWarningSeconds else { return }
                Log.info(String(format: "startup: no file-count change for %.0f s during %@ (%lld bytes on disk)",
                                stalled, self.loadPhase.description, self.downloadedBytes))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// File-count progress sits still while one large file transfers, so the
    /// size on disk is what shows the download is actually moving.
    private func measureDownloadedBytes() {
        let folder = Transcriber.modelFolder(in: Paths.supportDirectory)
        Task.detached(priority: .utility) {
            let bytes = Diagnostics.directorySize(at: folder)
            await MainActor.run { [weak self] in
                guard let self, bytes != self.downloadedBytes else { return }
                self.downloadedBytes = bytes
                Log.info("startup: \(bytes) bytes on disk")
            }
        }
    }

    // MARK: - Support

    func copyDiagnostics() {
        Task {
            let report = await diagnosticsReport()
            try? injector.inject(report)
            Log.info("diagnostics copied to clipboard")
        }
    }

    /// Writes the report to the unified log instead of the clipboard, for a
    /// machine where driving the menu bar is inconvenient.
    func logDiagnostics() {
        Task {
            let report = await diagnosticsReport()
            for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                Log.info("diag| \(line)")
            }
        }
    }

    private func diagnosticsReport() async -> String {
        await Diagnostics.report(
            storageDirectory: Paths.supportDirectory,
            status: statusText,
            lastError: lastErrorText,
            shortcut: shortcutDescription
        )
    }

    func revealModelFolder() {
        let folder = Transcriber.modelFolder(in: Paths.supportDirectory)
        let target = FileManager.default.fileExists(atPath: folder.path)
            ? folder
            : Paths.supportDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target.path)
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
        guard !isStartingRecording else {
            NSSound.beep()
            return
        }
        isStartingRecording = true

        Task {
            defer { isStartingRecording = false }

            guard await AudioRecorder.requestMicrophoneAccess() else {
                fail("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
                return
            }
            do {
                try await recorder.start()
                recordedSeconds = 0
                state = .recording

                silenceDetector = preferences.autoStopOnSilence
                    ? SilenceDetector(
                        dropDecibels: Float(preferences.silenceDropDecibels),
                        requiredSilence: preferences.silenceSeconds
                    )
                    : nil

                // Clear the previous result, or it flashes up for a frame when
                // the panel is shown again.
                overlay.model.levels = []
                overlay.model.elapsed = 0
                overlay.model.text = ""
                overlay.model.language = ""
                overlay.model.duration = 0
                overlay.model.message = ""
                overlay.present(.recording)

                if preferences.playSounds { Sounds.playStart() }

                HotkeyCenter.shared.setEnabled(true, for: .cancelDictation)
                startTicking()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func handleAudioConfigurationChange() {
        guard state == .recording else { return }
        Log.info(String(format: "audio: input configuration changed after %.1f s; finishing early",
                        recordedSeconds))
        finishRecording()
    }

    func cancel() {
        guard state == .recording else { return }

        // The state change and the UI happen now; tearing the engine down is
        // allowed to take as long as it takes. Nothing downstream needs the
        // captured audio, so there is nothing to wait for.
        state = .idle
        endRecordingSession()
        overlay.hideImmediately()

        Task { await recorder.cancel() }
    }

    private func finishRecording() {
        guard state == .recording else { return }

        // Moved ahead of the first suspension point. Stopping the engine is now
        // asynchronous, so the main thread stays free while it happens and the
        // shortcut, the tick timer and a device-change notification can all
        // arrive in that window. Each of those is guarded by `state ==
        // .recording`, so making the transition first is what turns them into
        // no-ops rather than a second attempt to finish the same recording.
        state = .transcribing
        endRecordingSession()
        overlay.update(.transcribing)

        Task {
            let samples = await recorder.stop()
            do {
                let output = try await transcriber.transcribe(samples: samples)
                guard !output.text.isEmpty else {
                    fail("Nothing was transcribed.")
                    return
                }

                let cleaned = await cleanup(output)

                try injector.inject(cleaned.text)
                record(output, cleaned: cleaned)

                overlay.model.text = cleaned.text
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

    /// Runs the configured post-processing over a transcript.
    ///
    /// Never throws. A cleanup that fails, times out, or has no server to talk
    /// to returns the transcript untouched: the user has already spoken, and
    /// losing that to an optional convenience would be a far worse bug than any
    /// defect cleanup was meant to fix.
    private func cleanup(_ output: Transcriber.Output) async -> CleanupResult {
        // Announced only when there is actually something to wait for. With
        // cleanup off the pass returns immediately, and showing the phase would
        // be a flicker with no information in it.
        if preferences.cleanupMode != .off {
            overlay.update(.cleaning)
        }

        switch preferences.cleanupMode {
        case .off:
            return .untouched(output.text)

        case .spelling:
            let result = SpellingCleaner().clean(output.text, language: output.language)
            report(result)
            return result

        case .model:
            guard let cleaner = embeddedCleaner else {
                return .untouched(output.text, mode: .model)
            }
            do {
                // Loads on demand. The first call after choosing this mode may
                // download several gigabytes, which is why the phase is
                // published rather than silently awaited.
                try await loadCleanupModel()
                let result = try await cleaner.clean(
                    output.text,
                    configuration: .init(glossary: preferences.glossaryTerms)
                )
                report(result)
                scheduleCleanupUnload()
                return result
            } catch {
                Log.error("Cleanup unavailable: \(error.localizedDescription)")
                return .untouched(output.text, mode: .model)
            }
        }
    }

    // MARK: - Cleanup model

    /// Loads the cleanup model, publishing progress as it goes.
    ///
    /// Cheap once loaded, so callers need not track whether it has run.
    func loadCleanupModel() async throws {
        guard let cleaner = embeddedCleaner else { return }
        cleanupUnloadTimer?.invalidate()
        try await cleaner.load { [weak self] phase in
            Task { @MainActor in self?.cleanupPhase = phase }
        }
    }

    /// Called when the user picks a cleanup mode, so a multi-gigabyte download
    /// starts while Settings is open rather than in the middle of a dictation.
    func prepareCleanupModel() {
        guard preferences.cleanupMode == .model else { return }
        Task {
            let started = Date()
            do {
                try await loadCleanupModel()
                Log.info(String(format: "cleanup model ready in %.2f s",
                                Date().timeIntervalSince(started)))
                scheduleCleanupUnload()
            } catch {
                Log.error("cleanup model failed to load: \(error.localizedDescription)")
                cleanupPhase = .idle
            }
        }
    }

    /// Drops the model after a period of inactivity.
    ///
    /// It occupies roughly 3.5 GB and reloads from a warm cache in about three
    /// seconds, so a machine doing other work is better off without it between
    /// dictation sessions.
    func scheduleCleanupUnload() {
        cleanupUnloadTimer?.invalidate()
        let minutes = preferences.cleanupIdleUnloadMinutes
        guard minutes > 0 else { return }

        cleanupUnloadTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes) * 60,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let cleaner = self.embeddedCleaner else { return }
                await cleaner.unload()
                self.cleanupPhase = .idle
                Log.info("cleanup model unloaded after \(minutes) min idle")
            }
        }
    }

    /// Records what a cleanup pass did.
    ///
    /// Timing and refusals are always logged: they describe the mechanism
    /// rather than the content, and a guard firing constantly is something the
    /// user should be able to discover. The text itself is logged only when
    /// explicitly enabled, because these entries are public and a dictation
    /// app's transcripts are not the system log's business by default.
    private func report(_ result: CleanupResult) {
        if !result.rejected.isEmpty {
            Log.info("cleanup[\(result.mode.rawValue)] rejected: \(result.rejected.joined(separator: "; "))")
        }
        guard result.changed else { return }

        Log.info(String(format: "cleanup[%@] changed in %.2f s",
                        result.mode.rawValue, result.duration))
        if preferences.logCleanupComparison {
            Log.info("cleanup before: \(result.original)")
            Log.info("cleanup after:  \(result.text)")
        }
    }

    private func record(_ output: Transcriber.Output, cleaned: CleanupResult) {
        history.insert(
            Transcription(
                text: cleaned.text,
                language: output.language,
                duration: output.duration,
                originalText: cleaned.changed ? cleaned.original : nil,
                cleanupSeconds: cleaned.changed ? cleaned.duration : nil
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
        HotkeyCenter.shared.setEnabled(false, for: .cancelDictation)
        recordedSeconds = 0
    }

    // MARK: - Launch at login

    /// Settable projection so SwiftUI can bind through `@Bindable`.
    ///
    /// A hand-written `Binding(get:set:)` would capture this MainActor-isolated
    /// object in closures stored in `Binding`'s nonisolated function type, which
    /// makes the runtime verify isolation on every call — including from
    /// SwiftUI's layout pass. That check crashed in 0.1.2.
    var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set { setLaunchAtLogin(newValue) }
    }

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
            Task { @MainActor in
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

    /// Deliberately avoids a microphone glyph. macOS already shows its own
    /// orange microphone indicator whenever the input is live, and a second
    /// microphone sitting next to it is redundant and confusing.
    var iconName: String {
        switch state {
        case .loading: "hourglass"
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .failed: "waveform.badge.exclamationmark"
        }
    }

    var statusText: String {
        switch state {
        case .loading:
            downloadedBytes > 0
                ? "\(loadPhase.description) · \(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) on disk"
                : loadPhase.description
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
        HotkeyCenter.shared.shortcut(for: .toggleDictation)?.description ?? "unassigned"
    }
}
