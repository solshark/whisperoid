import AppKit
import SwiftUI

@main
struct WhisperoidApp: App {

    @State private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.iconName)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {

    let controller: AppController

    var body: some View {
        Text(controller.statusText)

        Divider()

        Button(controller.state == .recording ? "Stop and Transcribe" : "Start Dictation") {
            controller.toggle()
        }
        .disabled(controller.state == .loading || controller.state == .transcribing)

        if controller.state == .recording {
            Button("Cancel (Escape)") {
                controller.cancel()
            }
        }

        Text("Shortcut: \(controller.shortcutDescription)")

        if !controller.history.isEmpty {
            Divider()

            Button("Copy Last Again") {
                controller.copyLastAgain()
            }

            Menu("History") {
                ForEach(controller.history) { item in
                    Button(Self.preview(of: item.text)) {
                        controller.copy(item)
                    }
                }
                Divider()
                Button("Clear History") {
                    controller.clearHistory()
                }
            }
        }

        Divider()

        Button("Preferences…") {
            controller.showSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Whisperoid") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private static func preview(of text: String) -> String {
        let limit = 50
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}
