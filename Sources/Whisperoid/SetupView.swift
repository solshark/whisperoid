import AppKit
import SwiftUI
import WhisperoidCore

/// First-launch checklist: the speech model, microphone access, and a first
/// dictation.
///
/// All three steps are on screen at once rather than paged, so microphone
/// access can be granted while the model downloads and nobody waits on a page
/// to advance. Every step reads live state from the controller, so the window
/// is correct whenever it is opened, including part-way through a download.
///
/// Nothing here uses `TimelineView`. The overlay's ribbons met a Swift runtime
/// fault through its per-frame isolation check; the one clock this window
/// needs, time spent preparing the model, is advanced by the controller.
struct SetupView: View {

    let controller: AppController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Whisperoid turns speech into text on this Mac. Your voice is never sent anywhere.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            modelStep
            microphoneStep
            tryItStep

            footer
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { controller.refreshMicrophoneAccess() }
        // The usual way back from System Settings after switching the
        // microphone on.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshMicrophoneAccess()
        }
    }

    // MARK: - Steps

    private var modelStep: some View {
        SetupStep(status: modelStatus, title: "Speech model") {
            if let error = controller.modelError {
                detail("Could not get the model ready: \(error)")
                // The error says what broke; this says what to do about it. Not
                // offered when preparation failed, which is not a network
                // problem.
                if controller.loadPhase != .preparing {
                    detail("Check your internet connection and try again. A download that was cut off carries on from where it stopped.")
                }
                Button("Try Again") { controller.retryModelLoad() }
            } else if controller.awaitingDownloadApproval {
                // App Store Review Guideline 4.2.3: state the size and ask
                // before downloading what the app needs to work.
                let size = controller.downloadSize.map(DownloadProgress.format)
                    ?? Transcriber.approximateDownloadSize
                detail("Needs a one-time download of \(size) from Hugging Face. After that, transcription works offline.")
                Button("Download (\(size))") { controller.approveModelDownload() }
                    .keyboardShortcut(.defaultAction)
            } else {
                switch controller.loadPhase {
                case .locating:
                    detail(controller.download == nil ? "Loading…" : "Starting the download…")
                case .downloading(let fileFraction, _, _):
                    downloadDetail(fileFraction: fileFraction)
                case .preparing:
                    detail("Preparing the model for this Mac. The first time, and after each macOS update, this can take a few minutes.")
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Elapsed \(Self.clock(controller.preparingSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                case .ready:
                    detail("Ready. Transcription works offline from now on.")
                }
            }
        }
    }

    @ViewBuilder
    private func downloadDetail(fileFraction: Double) -> some View {
        let download = controller.download ?? DownloadProgress()
        detail("One-time download, \(download.amountDescription)")
        // The file-count fraction stands in only until the model host has said
        // how large the download is.
        ProgressView(value: download.fraction ?? fileFraction)
        if let rate = download.rateDescription {
            Text(rate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var microphoneStep: some View {
        SetupStep(status: microphoneStatus, title: "Microphone access") {
            switch controller.microphoneAccess {
            case .undetermined:
                detail("Needed to hear you.")
                Button("Allow Microphone") { controller.requestMicrophoneAccess() }
            case .granted:
                detail("Allowed.")
            case .denied:
                detail("Switched off for Whisperoid. Turn it on in System Settings, then come back here.")
                Button("Open System Settings") { controller.openMicrophoneSettings() }
            }
        }
    }

    private var tryItStep: some View {
        SetupStep(status: controller.history.isEmpty ? .pending : .done, title: "Try it") {
            if let latest = controller.history.first {
                detail("It works. This is on your clipboard, ready to paste anywhere with Command-V:")
                transcript(latest.text)
            } else if let spelled = controller.shortcutSpelledOut {
                detail("Press \(controller.shortcutDescription) (\(spelled)), speak, then press it again. The text lands on your clipboard, ready to paste.")
            } else {
                detail("Assign a dictation shortcut in Preferences first.")
            }
        }
        .opacity(controller.isSetupComplete || !controller.history.isEmpty ? 1 : 0.5)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if controller.awaitingDownloadApproval {
                Button("Later", action: onClose)
            } else if !controller.isModelReady {
                Button("Continue in Background", action: onClose)
            }
            // Return belongs to Download while that is the question being asked.
            Button("Done", action: onClose)
                .keyboardShortcut(controller.isModelReady ? .defaultAction : nil)
                .disabled(!controller.isModelReady)
        }
    }

    // MARK: - Status

    private var modelStatus: StepStatus {
        if controller.modelError != nil { return .problem }
        if controller.awaitingDownloadApproval { return .pending }
        return controller.isModelReady ? .done : .active
    }

    private var microphoneStatus: StepStatus {
        switch controller.microphoneAccess {
        case .undetermined: .pending
        case .granted: .done
        case .denied: .problem
        }
    }

    // MARK: - Helpers

    /// What the first dictation produced, so the user sees the result rather
    /// than being told it worked. The newest one, if they try more than once.
    ///
    /// Capped in height: the window sizes itself to its content, and a long
    /// first recording would otherwise push it past the bottom of the screen.
    private func transcript(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private enum StepStatus {
    case pending
    case active
    case done
    case problem
}

/// One row of the checklist: a status mark, a title, and whatever the step
/// needs underneath.
private struct SetupStep<Content: View>: View {

    let status: StepStatus
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                content
            }
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
