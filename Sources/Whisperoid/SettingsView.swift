import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {

    @Bindable var controller: AppController

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Start and stop dictation") {
                    ShortcutRecorder(name: .toggleDictation)
                        .frame(width: 160, height: 24)
                }
                LabeledContent("Discard recording") {
                    ShortcutRecorder(name: .cancelDictation)
                        .frame(width: 160, height: 24)
                }
                caption("Discard is only active while recording. Press Escape to abandon a capture, Delete to clear a shortcut.")
            }

            Section("Recording") {
                Toggle(
                    "Stop automatically after a silence",
                    isOn: binding(\.autoStopOnSilence)
                )

                // Kept visible and disabled rather than hidden: showing and
                // hiding them changes the content height, and the window is
                // sized to its content when it is created. Scoped to a Group so
                // the toggle above stays usable.
                Group {
                    LabeledContent("Silence before stopping") {
                        sliderRow(
                            value: binding(\.silenceSeconds),
                            range: Preferences.silenceRange,
                            step: 0.5,
                            text: String(format: "%.1f s", controller.preferences.silenceSeconds)
                        )
                    }

                    LabeledContent("Counts as silence below") {
                        sliderRow(
                            value: binding(\.silenceDropDecibels),
                            range: Preferences.dropRange,
                            step: 1,
                            text: String(format: "%.0f dB", controller.preferences.silenceDropDecibels)
                        )
                    }

                    caption("Measured against your loudest speech, so it adapts to microphone gain. Lower stops sooner; past about 25 dB it may never stop. Recording always stops after \(Int(AppController.maximumRecordingSeconds / 60)) minutes.")
                }
                .disabled(!controller.preferences.autoStopOnSilence)
            }

            Section("Feedback") {
                Toggle("Play sounds", isOn: binding(\.playSounds))
            }

            Section("General") {
                Toggle(
                    "Open at login",
                    isOn: Binding(
                        get: { controller.launchAtLoginEnabled },
                        set: { controller.setLaunchAtLogin($0) }
                    )
                )

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

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<Preferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.preferences[keyPath: keyPath] },
            set: { controller.preferences[keyPath: keyPath] = $0 }
        )
    }

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
