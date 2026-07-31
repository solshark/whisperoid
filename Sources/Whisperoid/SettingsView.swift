import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {

    @Bindable var controller: AppController

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Start and stop dictation:", name: .toggleDictation)
                KeyboardShortcuts.Recorder("Discard recording:", name: .cancelDictation)
                Text("The discard shortcut is only active while recording, so it behaves normally the rest of the time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Toggle(
                    "Stop automatically after a silence",
                    isOn: Binding(
                        get: { controller.preferences.autoStopOnSilence },
                        set: { controller.preferences.autoStopOnSilence = $0 }
                    )
                )

                if controller.preferences.autoStopOnSilence {
                    let seconds = controller.preferences.silenceSeconds
                    Slider(
                        value: Binding(
                            get: { controller.preferences.silenceSeconds },
                            set: { controller.preferences.silenceSeconds = $0 }
                        ),
                        in: Preferences.silenceRange,
                        step: 0.5
                    ) {
                        Text(String(format: "Silence before stopping: %.1f s", seconds))
                    }
                    let drop = controller.preferences.silenceDropDecibels
                    Slider(
                        value: Binding(
                            get: { controller.preferences.silenceDropDecibels },
                            set: { controller.preferences.silenceDropDecibels = $0 }
                        ),
                        in: Preferences.dropRange,
                        step: 1
                    ) {
                        Text(String(format: "Counts as silence below: %.0f dB under your voice", drop))
                    }

                    Text("The threshold follows the loudest speech in each recording, so it adapts to microphone gain. Lower values make it more eager to stop and can cut you off between phrases; above roughly 25 dB it falls below room noise and never stops at all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Only applies once you have started speaking, so a pause before your first word will not end the recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Recording always stops after \(Int(AppController.maximumRecordingSeconds / 60)) minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle(
                    "Play sounds",
                    isOn: Binding(
                        get: { controller.preferences.playSounds },
                        set: { controller.preferences.playSounds = $0 }
                    )
                )
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

                Text("Move Whisperoid to your Applications folder before enabling this; the login item records wherever the app currently lives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A fixed vertical size would force the window taller than a 1080-point
        // display; a maximum lets the form scroll instead.
        .frame(width: 460)
        .frame(minHeight: 420, maxHeight: 760)
        // Activation and ordering are handled by SettingsWindowController.
        .onAppear { controller.refreshLaunchAtLogin() }
    }
}
