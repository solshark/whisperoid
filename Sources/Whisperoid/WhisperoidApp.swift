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

    @Bindable var controller: AppController

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

        if !controller.lastText.isEmpty {
            Divider()
            Text(preview(of: controller.lastText))
            Button("Copy Again") {
                controller.copyLastAgain()
            }
        }

        Divider()

        Button("Quit Whisperoid") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func preview(of text: String) -> String {
        let limit = 60
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
