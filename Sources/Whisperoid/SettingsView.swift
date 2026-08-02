import AppKit
import SwiftUI

/// All bindings here go through `@Bindable`, never a hand-written
/// `Binding(get:set:)`.
///
/// `SettingsView` is inferred `@MainActor` through its `View` conformance, so a
/// closure written here is MainActor-isolated. Storing one in `Binding`, whose
/// getter and setter are nonisolated function types, makes the runtime verify
/// isolation on every call. SwiftUI calls those getters from its layout pass,
/// and in 0.1.2 that check faulted inside `SerialExecutor._isSameExecutor` and
/// crashed the app. `@Bindable` builds bindings from key paths instead, so no
/// such closure exists.
struct SettingsView: View {

    @Bindable var controller: AppController
    @Bindable var preferences: Preferences

    /// Forces the recorders to re-read their titles after Restore Defaults,
    /// which changes the bindings without going through the recorder.
    @State private var shortcutRevision = 0

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Start and stop dictation") {
                    ShortcutRecorder(name: .toggleDictation, revision: shortcutRevision)
                        .frame(width: 160, height: 24)
                }
                LabeledContent("Discard recording") {
                    ShortcutRecorder(name: .cancelDictation, revision: shortcutRevision)
                        .frame(width: 160, height: 24)
                }

                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        HotkeyCenter.shared.resetToDefaults()
                        shortcutRevision += 1
                    }
                }

                caption("Discard is only active while recording. Press Escape to abandon a capture, Delete to clear a shortcut.")
            }

            Section("Recording") {
                Toggle("Stop automatically after a silence", isOn: $preferences.autoStopOnSilence)

                // Kept visible and disabled rather than hidden: showing and
                // hiding them changes the content height, and the window is
                // sized to its content when it is created. Scoped to a Group so
                // the toggle above stays usable.
                Group {
                    LabeledContent("Silence before stopping") {
                        sliderRow(
                            value: $preferences.silenceSeconds,
                            range: Preferences.silenceRange,
                            step: 0.5,
                            text: String(format: "%.1f s", preferences.silenceSeconds)
                        )
                    }

                    LabeledContent("Counts as silence below") {
                        sliderRow(
                            value: $preferences.silenceDropDecibels,
                            range: Preferences.dropRange,
                            step: 1,
                            text: String(format: "%.0f dB", preferences.silenceDropDecibels)
                        )
                    }

                    caption("Measured against your loudest speech, so it adapts to microphone gain. Lower stops sooner; past about 25 dB it may never stop. Recording always stops after \(Int(AppController.maximumRecordingSeconds / 60)) minutes.")
                }
                .disabled(!preferences.autoStopOnSilence)
            }

            Section("Feedback") {
                Toggle("Play sounds", isOn: $preferences.playSounds)
            }

            Section("General") {
                Toggle("Open at login", isOn: $controller.launchAtLogin)

                if let message = controller.launchAtLoginMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Login Items…") {
                        LaunchAtLogin.openLoginItemsSettings()
                    }
                }

                caption("Move Whisperoid to Applications before enabling; the login item records where the app currently lives.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        // Activation and placement are handled by SettingsWindowController.
        .onAppear { controller.refreshLaunchAtLogin() }
    }

    // MARK: - Building blocks

    private func sliderRow(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step)
            Text(text)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
