import AppKit
import SwiftUI
import WhisperoidCore

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
///
/// Laid out as tabs rather than one long form. As a single form it had grown to
/// 662 points before cleanup was added and past the height of a laptop display
/// after, which put the last section out of reach on the machine most likely to
/// be running this.
struct SettingsView: View {

    @Bindable var controller: AppController
    @Bindable var preferences: Preferences

    /// Forces the recorders to re-read their titles after Restore Defaults,
    /// which changes the bindings without going through the recorder.
    @State private var shortcutRevision = 0

    /// Fits the tallest tab. Fixed rather than per-tab, because the window is
    /// sized once from its content and cannot resize itself as tabs change.
    /// Each tab's form scrolls if it ever outgrows this.
    private static let contentHeight: CGFloat = 390

    var body: some View {
        TabView {
            shortcuts
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            recording
                .tabItem { Label("Recording", systemImage: "waveform") }
            cleanup
                .tabItem { Label("Cleanup", systemImage: "text.badge.checkmark") }
            general
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: Self.contentHeight)
        // Activation and placement are handled by SettingsWindowController.
        .onAppear { controller.refreshLaunchAtLogin() }
    }

    // MARK: - Tabs

    private var shortcuts: some View {
        Form {
            Section {
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

                caption("Discard is only active while recording. Press Escape to abandon a capture, Delete to clear a shortcut. Some combinations are taken by macOS before this window sees them and cannot be recorded by pressing them — ⌘⌃D, the default, opens Look Up. Restore Defaults sets bindings directly, so it always works.")
            }
        }
        .formStyle(.grouped)
    }

    private var recording: some View {
        Form {
            Section {
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
        }
        .formStyle(.grouped)
    }

    private var cleanup: some View {
        Form {
            Section {
                Picker("Correct the transcript", selection: $preferences.cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                caption("Spelling uses the macOS spelling service, costs nothing and works offline, but only ever splits a run-together word, changes its case or restores an accent — it will not touch technical vocabulary. The language model can also correct misheard product names, but needs Ollama running locally with the gemma3:4b model, and holds about 4 GB of memory while it works. If it is unavailable the transcript is used unchanged.")

                Group {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Terms to recognise, one per line")
                            .font(.callout)
                        TextEditor(text: $preferences.cleanupGlossary)
                            .font(.body.monospaced())
                            .frame(height: 92)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.separator)
                            )
                    }

                    caption("This list is what makes the model mode work: without it the models tested corrected roughly one defect in six, and with it four to six. Listing a term once is enough — the model matches mishearings and transliterations of it, so Colima also catches Kolyma and Колема. Do not list two spellings of the same thing.")
                }
                .disabled(preferences.cleanupMode != .model)
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Play sounds", isOn: $preferences.playSounds)
            }

            Section {
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
