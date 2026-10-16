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
    private var watchdog: Timer?

    /// Byte-level progress of the model download, shown in the setup window.
    /// Nil when the model was already on disk and nothing is being fetched.
    private(set) var download: DownloadProgress?
    /// Size of the model download, from the model host. Shown before the
    /// download is approved, and the progress bar's total during it.
    private(set) var downloadSize: Int64?
    /// True while the model is missing and the user has not yet agreed to
    /// download it.
    private(set) var awaitingDownloadApproval = false
    @ObservationIgnored private var isLookingUpDownloadSize = false
    /// Set when this launch downloaded the model, as opposed to finding it on
    /// disk, so the end of that download can be brought to the user's notice.
    @ObservationIgnored private var downloadedThisSession = false
    /// Seconds spent so far in Core ML preparation, which reports no progress
    /// of its own. Advanced by the progress timer.
    private(set) var preparingSeconds = 0
    /// Why the model could not be made ready, until a retry succeeds.
    private(set) var modelError: String?
    private(set) var microphoneAccess = AudioRecorder.microphoneAccess
    @ObservationIgnored private var downloadMeter = DownloadMeter()
    @ObservationIgnored private var preparingSince: Date?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var loggedDownloadBytes: Int64 = -1

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
    @ObservationIgnored private var setupWindow: HostedWindowController<SetupView>?
    private var tickTimer: Timer?
    private var silenceDetector: SilenceDetector?
    /// When the input device was last opened for the current recording, and
    /// whether it is being reopened right now. See `reopenSilentInputSeconds`.
    @ObservationIgnored private var inputOpenedAt = Date()
    @ObservationIgnored private var isReopeningInput = false
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

    func showSetup() {
        refreshMicrophoneAccess()
        if setupWindow == nil {
            setupWindow = HostedWindowController(
                title: "Welcome to Whisperoid",
                diagnosticName: "setup"
            ) { [unowned self] in
                SetupView(controller: self, onClose: { [unowned self] in
                    self.setupWindow?.close()
                })
            }
        }
        setupWindow?.show()
    }

    /// Whether the app has what it needs to dictate: the model on disk and the
    /// microphone allowed.
    ///
    /// Derived from the state of the machine rather than remembered as "setup
    /// was completed once". A deleted model folder, or a build signed by a
    /// different team, which macOS treats as a different app and so asks about
    /// the microphone again, both bring back a step that genuinely needs doing.
    static var isSetUp: Bool {
        Transcriber.localModel(in: Paths.supportDirectory) != nil
            && AudioRecorder.microphoneAccess == .granted
    }

    var isModelReady: Bool { loadPhase == .ready }

    var isSetupComplete: Bool { isModelReady && microphoneAccess == .granted }

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

        recorder.onDiagnostic = { note in
            Log.info("audio: \(note)")
        }

        // The user is told about this by the error the operation throws. The log
        // entry is for afterwards: a hang that leaves no trace has to be caught
        // in the act to be diagnosed at all.
        let engineTimeout = recorder.engineTimeout
        recorder.onEngineTimeout = { operation in
            Log.error(String(format: "audio: %@ exceeded %.0f s; abandoning the audio queue "
                             + "and starting a new one", operation, engineTimeout))
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

        // A first launch otherwise leaves the user with an hourglass in the menu
        // bar and nothing to say that 1.6 GB is on its way.
        if environment["WHISPEROID_SHOW_SETUP"] != nil || !Self.isSetUp {
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                showSetup()
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

    /// Loads the model, downloading it first only with the user's go-ahead.
    ///
    /// The download is 1.6 GB, and App Store Review Guideline 4.2.3 asks that
    /// an app which must download resources before it works on first launch
    /// disclose the size and ask before doing so. Every build asks, rather than
    /// only the App Store one: a direct download is no less 1.6 GB on a
    /// metered connection.
    private func loadModel(downloadApproved: Bool = false) async {
        if !downloadApproved, Transcriber.localModel(in: Paths.supportDirectory) == nil {
            awaitingDownloadApproval = true
            Log.info("startup: model not on disk; waiting for the download to be approved")
            lookUpDownloadSize()
            return
        }

        let started = Date()
        startWatchdog()
        startProgressTimer()
        defer {
            stopWatchdog()
            stopProgressTimer()
            preparingSince = nil
            download = nil
        }

        do {
            let directory = try Paths.ensureSupportDirectory()
            let cached = Transcriber.localModel(in: directory) != nil
            Log.info("startup: variant=\(Transcriber.modelVariant) storage=\(directory.path)")
            #if KEEP_RECORDINGS
            Log.info("startup: debug build, keeping every recording in \(RecordingArchive.directory.path)")
            #endif
            Log.info("startup: model folder \(Transcriber.modelFolder(in: directory).path)")
            Log.info(cached
                ? "startup: model already on disk, skipping network"
                : "startup: model not cached, will download")

            if !cached { beginDownloadTracking() }

            try await transcriber.load(storageDirectory: directory) { [weak self] phase in
                Task { @MainActor in self?.apply(phase) }
            }

            Log.info(String(format: "startup: ready in %.2f s", Date().timeIntervalSince(started)))
            lastErrorText = nil
            modelError = nil
            state = .idle
            announceDownloadOutcome()

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
            modelError = error.localizedDescription
            state = .failed("Model load failed: \(error.localizedDescription)")
            announceDownloadOutcome()
        }
    }

    /// Brings the end of a download to the user's notice, whichever way it
    /// went.
    ///
    /// A download left running with "Continue in Background" otherwise ends
    /// with nobody watching: the menu bar icon changes and nothing else does. A
    /// failure is worse, discovered only when the shortcut later beeps. The
    /// setup window comes back showing the outcome and whatever steps are still
    /// open, and the Dock icon bounces once in case the user is in another app.
    /// A notification would need yet another permission prompt; this needs
    /// none.
    private func announceDownloadOutcome() {
        guard downloadedThisSession else { return }
        downloadedThisSession = false
        showSetup()

        // The Dock icon only exists once `showSetup` has switched the app to the
        // regular activation policy, which takes effect a runloop turn later.
        // The request does nothing if the user is already looking at the app.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Tries again after a failed load. A download that was cut off resumes
    /// from the bytes already on disk rather than starting over.
    func retryModelLoad() {
        guard modelError != nil, state != .loading else { return }
        modelError = nil
        loadPhase = .locating
        state = .loading
        // Pressing Try Again is itself the go-ahead for the download.
        Task { await loadModel(downloadApproved: true) }
    }

    /// The user's go-ahead for the model download.
    func approveModelDownload() {
        guard awaitingDownloadApproval else { return }
        awaitingDownloadApproval = false
        Log.info("startup: download approved")
        Task { await loadModel(downloadApproved: true) }
    }

    /// Asks the model host how big the download is, once.
    ///
    /// Only the file listing is fetched, a few kilobytes, so this can run
    /// before the download is approved. A slow or failed answer must not hold
    /// anything up: the download proceeds without a total, and the approval
    /// prompt falls back to an approximate size.
    private func lookUpDownloadSize() {
        guard downloadSize == nil, !isLookingUpDownloadSize else { return }
        isLookingUpDownloadSize = true
        Task {
            defer { isLookingUpDownloadSize = false }
            do {
                let total = try await ModelCatalog.downloadSize(
                    repository: Transcriber.modelRepository,
                    variant: Transcriber.modelVariant
                )
                downloadSize = total
                download?.totalBytes = total
                Log.info("startup: download size \(total) bytes")
            } catch {
                Log.error("startup: download size unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Starts byte-level tracking of a download that is about to begin.
    private func beginDownloadTracking() {
        downloadedThisSession = true
        download = DownloadProgress(totalBytes: downloadSize)
        downloadMeter = DownloadMeter()
        lookUpDownloadSize()
    }

    private func apply(_ phase: Transcriber.Phase) {
        loadPhase = phase
        phaseChangedAt = Date()

        if case .preparing = phase, preparingSince == nil {
            preparingSince = Date()
            preparingSeconds = 0
        }

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
                self.logDownloadedBytes()

                let stalled = Date().timeIntervalSince(self.phaseChangedAt)
                guard stalled >= Self.stallWarningSeconds else { return }
                Log.info(String(format: "startup: no file-count change for %.0f s during %@ (%lld bytes on disk)",
                                stalled, self.loadPhase.description, self.download?.bytes ?? 0))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Logged on the watchdog's slow beat rather than on every sample, so the
    /// unified log shows the download moving without being flooded by it.
    private func logDownloadedBytes() {
        guard let download, download.bytes != loggedDownloadBytes else { return }
        loggedDownloadBytes = download.bytes
        let total = download.totalBytes.map { "\($0)" } ?? "unknown"
        Log.info("startup: \(download.bytes) of \(total) bytes on disk")
    }

    /// Samples the download and the preparation clock twice a second, for the
    /// setup window. Kept apart from the watchdog, which beats slowly because
    /// its job is the log, not the display.
    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tickProgress() {
        if let preparingSince {
            let seconds = Int(Date().timeIntervalSince(preparingSince))
            if seconds != preparingSeconds { preparingSeconds = seconds }
            return
        }
        guard download != nil else { return }

        // File-count progress sits still while one large file transfers, so the
        // size on disk, in-flight files included, is what shows the download
        // actually moving.
        let directory = Paths.supportDirectory
        Task.detached(priority: .utility) {
            let bytes = Transcriber.downloadedBytes(in: directory)
            await MainActor.run { [weak self] in
                self?.recordDownload(bytes: bytes)
            }
        }
    }

    private func recordDownload(bytes: Int64) {
        guard var progress = download else { return }
        downloadMeter.record(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
        progress.bytes = bytes
        progress.bytesPerSecond = downloadMeter.bytesPerSecond
        download = progress
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

            let granted = await AudioRecorder.requestMicrophoneAccess()
            // The first dictation may be what prompted for access, and the setup
            // window, if open, should reflect the answer.
            refreshMicrophoneAccess()
            guard granted else {
                fail("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
                return
            }
            do {
                try await recorder.start()
                inputOpenedAt = Date()
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
                // Not `.recording`: the device is open but may not be producing
                // sound yet. Showing a live timer through that window is what
                // invites the user to start talking into silence.
                overlay.present(recorder.hasHeardAudio ? .recording : .warmingUp)

                if preferences.playSounds { Sounds.playStart() }

                HotkeyCenter.shared.setEnabled(true, for: .cancelDictation)
                startTicking()
            } catch {
                fail(error.localizedDescription)
            }
        }
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

    private func finishRecording(stalled: Bool = false) {
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
            let seconds = Double(samples.count) / AudioRecorder.targetSampleRate

            #if KEEP_RECORDINGS
            let archiveName = RecordingArchive.baseName(for: Date())
            keep { try RecordingArchive.saveAudio(samples, named: archiveName) }
            #endif

            // The two numbers that separate "the microphone gave us nothing"
            // from "the transcriber did nothing with it", and both of those
            // from "the microphone was open but heard almost nothing". All
            // three used to arrive as the same unhelpful error.
            var peak: Float = 0
            var sumOfSquares: Float = 0
            var zeros = 0
            for sample in samples {
                peak = max(peak, abs(sample))
                sumOfSquares += sample * sample
                if sample == 0 { zeros += 1 }
            }
            let rms = (sumOfSquares / Float(max(samples.count, 1))).squareRoot()
            let decibels = { (value: Float) in 20 * log10(max(value, 1e-9)) }

            Log.info(String(format: "audio: finishing with %.2f s captured, peak %.1f dBFS, rms %.1f dBFS",
                            seconds, decibels(peak), decibels(rms)))

            // A recording that the hardware ended before it produced anything
            // usable is not a recording the user cut short, and saying "too
            // short" sends them off to speak for longer at a microphone that is
            // not listening. Observed with AirPods over Bluetooth on macOS 26.6,
            // where selecting them as the input never yields a microphone
            // stream at all.
            // Buffers arrived, on time and in the right format, and every
            // sample in them was zero. That is not a quiet room, it is a device
            // handing over silence. Seen with AirPods that another of the
            // user's devices was playing to: they refused the Mac their
            // microphone, and reconnecting them did not change that. Nothing
            // downstream can do anything useful with it, and "nothing was
            // transcribed" sends the user looking at the wrong thing. The same
            // goes for a few milliseconds of sound followed by zeros, which is
            // how AirPods that the Mac did own sent a 43-second dictation:
            // given that, Whisper returned "Thank you."
            if AudioRecorder.isSilentInput(samples), seconds >= Transcriber.minimumSeconds {
                Log.error(String(format: "audio: %.2f s captured but nothing came through: %.1f%% of samples "
                                 + "were bit-exact silence", seconds, 100 * Double(zeros) / Double(max(samples.count, 1))))
                fail(Self.silentInputFailure(for: recorder.inputDevice))
                return
            }

            if stalled, seconds < Transcriber.minimumSeconds {
                Log.error("audio: input device delivered nothing for "
                          + "\(Self.audioStallSeconds) s; giving up on this recording")
                fail("No audio is coming from the current input device. Check that the "
                     + "right microphone is selected in System Settings > Sound > Input, "
                     + "and that nothing else has taken it.")
                return
            }

            do {
                let output = try await transcriber.transcribe(
                    samples: samples,
                    glossary: preferences.promptWithGlossary ? preferences.glossaryTerms : []
                )
                #if KEEP_RECORDINGS
                keep { try RecordingArchive.saveText(output.text, named: archiveName) }
                #endif
                guard !output.text.isEmpty else {
                    fail("Nothing was transcribed.")
                    return
                }

                Log.info(String(format: "transcribed %d characters, language %@, in %.2f s, glossary prompt %d tokens, "
                                + "%d chunks, gain %+.1f dB, pause threshold %.1f dBFS",
                                output.text.count, output.language, output.duration,
                                output.promptTokens, output.chunks, output.inputGainDecibels,
                                output.pauseThresholdDecibels))
                if output.unheardSegments > 0 {
                    Log.info("transcription: left out \(output.unheardSegments) segment(s) "
                             + "with no sound above the pause threshold")
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

        case .appleModel:
            // Nothing to load or unload: the system model lives outside this
            // process and macOS manages its memory.
            do {
                let result = try await SystemModelCleaner().clean(
                    output.text,
                    glossary: preferences.glossaryTerms
                )
                report(result)
                return result
            } catch {
                Log.error("Cleanup unavailable: \(error.localizedDescription)")
                return .untouched(output.text, mode: .appleModel)
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
    /// Timing, and how many corrections of each kind were refused, are always
    /// logged: they describe the mechanism rather than the content, and a guard
    /// firing constantly is something the user should be able to discover. Any
    /// words from the dictation, whether in the text before and after or in a
    /// refused correction, are logged only when explicitly enabled, because
    /// these entries are public and a dictation app's transcripts are not the
    /// system log's business by default.
    private func report(_ result: CleanupResult) {
        Refusal.logLines(for: result.rejected, mode: result.mode.rawValue,
                         includingWords: preferences.logCleanupComparison).forEach(Log.info)
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
        Log.error("failed: \(message)")
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

    // MARK: - Microphone access

    func requestMicrophoneAccess() {
        Task {
            _ = await AudioRecorder.requestMicrophoneAccess()
            refreshMicrophoneAccess()
        }
    }

    /// macOS sends no notification when the permission changes, so this is
    /// re-read whenever the answer might be different: the setup window
    /// appearing, the app becoming active again after a trip to System
    /// Settings, and a dictation having asked.
    func refreshMicrophoneAccess() {
        let current = AudioRecorder.microphoneAccess
        if current != microphoneAccess { microphoneAccess = current }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
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

    /// How long a recording may go without audio before it is given up on.
    ///
    /// Has to clear the pause between starting the engine and the first buffer,
    /// which is not instant on Bluetooth: AirPods Max took 0.377 s to switch
    /// into their headset profile on macOS 26.6. Several times that leaves room
    /// for a slower device without making a genuinely dead one wait long.
    private static let audioStallSeconds: Double = 3

    /// How long a device may send only bit-exact silence before the overlay
    /// says so.
    ///
    /// AirPods Max woke within 0.8 s in all 36 recordings measured, and wired
    /// microphones produce sound from the first buffer. Silence well past that
    /// is a device that is open but not listening.
    private static let silentInputHintSeconds: Double = 2

    /// How often a device that has sent only silence is reopened.
    ///
    /// Each opening has to be given time to wake: AirPods Max took up to 0.8 s,
    /// and reopening sooner would interrupt a headset that was about to answer.
    private static let reopenSilentInputSeconds: Double = 3

    /// Shown in place of GETTING READY while the device sends only silence.
    private static func silentInputHint(for device: AudioRecorder.InputDevice?, afterSound: Bool) -> String {
        let name = device?.name ?? "the microphone"
        // The device worked a moment ago, so its settings are not the cause.
        if afterSound {
            return "Sound from \(name) has stopped. Reopening it; if this goes on, stop and try again."
        }
        if device?.isBluetooth == true {
            return "No sound from \(name) yet. If another of your devices is playing to it, "
                + "pause the audio there and wait a moment."
        }
        return "No sound from \(name) yet. Check that it is not muted and its input volume is up."
    }

    /// Shown when a recording ends having received only silence.
    private static func silentInputFailure(for device: AudioRecorder.InputDevice?) -> String {
        let name = device?.name ?? "the microphone"
        if device?.isBluetooth == true {
            return "Only silence came from \(name). If another of your devices is playing to it, "
                + "pause the audio there and try again."
        }
        return "Only silence came from \(name). Check that it is not muted and its input volume "
            + "is up, then try again."
    }

    private func startTicking() {
        stopTicking()

        let timer = Timer(timeInterval: Self.waveformInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }

                self.recordedSeconds = self.recorder.recordedSeconds
                self.overlay.model.levels = self.recorder.recentLevels
                self.overlay.model.elapsed = self.recordedSeconds

                // The device has started producing sound, so the recording is
                // genuinely under way and the user can be invited to speak.
                if self.overlay.model.phase == .warmingUp, self.recorder.hasHeardAudio {
                    self.overlay.model.message = ""
                    self.overlay.update(.recording)
                }

                let silent = self.recorder.silentSeconds

                // Sound again after a silent stretch: the hint has done its job.
                if self.overlay.model.phase == .recording, !self.overlay.model.message.isEmpty,
                   silent < Self.silentInputHintSeconds
                {
                    self.overlay.model.message = ""
                }

                // Nothing but zeros, long after a headset would have woken or
                // a working microphone would have picked up the room. Say why
                // rather than leave the user talking to a device that is not
                // listening, and keep listening: once the cause is cleared the
                // device produces sound and the branches above take over. Not
                // only at the start: AirPods have produced a moment of sound
                // and then nothing but zeros for a whole dictation.
                if self.overlay.model.message.isEmpty, silent >= Self.silentInputHintSeconds {
                    let device = self.recorder.inputDevice
                    Log.info(String(format: "audio: only silence for %.1f s from %@%@%@; showing a hint",
                                    silent, device?.name ?? "unknown device",
                                    device?.isBluetooth == true ? " (Bluetooth)" : "",
                                    self.recorder.hasHeardAudio ? " after sound" : ""))
                    self.overlay.model.message = Self.silentInputHint(
                        for: device, afterSound: self.recorder.hasHeardAudio)
                }

                // macOS asks a headset for its microphone only when the device is
                // opened. Reopening it while nothing is heard is what lets this
                // recording come alive once the other device lets go, rather
                // than only the next one.
                if silent >= Self.reopenSilentInputSeconds, !self.isReopeningInput,
                   Date().timeIntervalSince(self.inputOpenedAt) >= Self.reopenSilentInputSeconds
                {
                    self.reopenSilentInput()
                }

                if self.recordedSeconds >= Self.maximumRecordingSeconds {
                    self.finishRecording()
                    return
                }

                // The device has stopped answering, or never started. Whatever
                // has already been captured is still worth transcribing.
                if self.recorder.secondsSinceAudio > Self.audioStallSeconds {
                    self.finishRecording(stalled: true)
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

    #if KEEP_RECORDINGS
    /// Debug builds only; see `RecordingArchive`. A failure to save is logged
    /// and otherwise ignored, so it can never cost the user a dictation.
    private func keep(_ save: () throws -> URL) {
        do {
            Log.info("debug: kept \(try save().lastPathComponent)")
        } catch {
            Log.error("debug: could not keep the recording: \(error.localizedDescription)")
        }
    }
    #endif

    /// Reopens an input device that has sent only silence, so that macOS asks
    /// it for its microphone again.
    private func reopenSilentInput() {
        isReopeningInput = true
        Log.info("audio: reopening \(recorder.inputDevice?.name ?? "the input device") "
                 + "to ask for its microphone again")
        Task {
            defer {
                isReopeningInput = false
                inputOpenedAt = Date()
            }
            do {
                try await recorder.restartCapture()
            } catch {
                Log.error("audio: reopening the input device failed: \(error.localizedDescription)")
            }
        }
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
        // Waiting on the user rather than on work, so not an hourglass.
        case .loading: awaitingDownloadApproval ? "arrow.down.circle" : "hourglass"
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .failed: "waveform.badge.exclamationmark"
        }
    }

    var statusText: String {
        switch state {
        case .loading:
            if awaitingDownloadApproval {
                "Speech model not downloaded yet"
            } else if case .downloading = loadPhase, let download {
                "Downloading model… \(download.amountDescription)"
            } else {
                loadPhase.description
            }
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

    /// Nil when no dictation shortcut is assigned.
    var shortcutSpelledOut: String? {
        HotkeyCenter.shared.shortcut(for: .toggleDictation)?.spelledOut
    }
}
