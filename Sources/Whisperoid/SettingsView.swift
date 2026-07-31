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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { controller.refreshLaunchAtLogin() }
    }
}
