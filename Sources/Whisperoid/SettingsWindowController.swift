import AppKit
import SwiftUI

/// Owns the preferences window directly rather than relying on SwiftUI's
/// `Settings` scene.
///
/// Neither `NSApp.sendAction(Selector(("showSettingsWindow:")))` nor
/// `SettingsLink` opens that scene from a `MenuBarExtra` using the `.menu`
/// style; both fail silently, because the menu is rendered as a native NSMenu
/// and the SwiftUI activation machinery is not in the responder chain.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func show(controller: AppController) {
        let window = existingWindow(for: controller)

        // The app runs as an accessory so it has no Dock icon, but an accessory
        // cannot reliably take key focus, and the shortcut recorders are useless
        // without it. Becoming a regular app for as long as this window is open
        // gives it normal activation, at the cost of a temporary Dock icon.
        NSApp.setActivationPolicy(.regular)

        // The policy change needs a runloop turn before activation will take
        // effect. Activating in the same turn leaves the window visible but
        // unfocused and behind the frontmost application, which reads as the
        // menu item having done nothing at all.
        DispatchQueue.main.async {
            NSApp.activate()
            NSRunningApplication.current.activate(options: [.activateAllWindows])

            if !window.isVisible { self.centreOnActiveScreen(window) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        // Activation is asynchronous, so key status is not settled immediately.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            let frame = window.frame
            Log.info("settings visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "policy=\(NSApp.activationPolicy() == .regular ? "regular" : "accessory") "
                + "active=\(NSApp.isActive) "
                + "frame=\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY)) "
                + "level=\(window.level.rawValue) onScreen=\(window.isOnActiveSpace)")
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Centres on the display holding the pointer.
    ///
    /// `NSWindow.center()` uses the main screen, which on a multi-display setup
    /// routinely places the window on a monitor the user is not looking at. An
    /// unfocused window on another screen is indistinguishable from the menu
    /// item having done nothing.
    private func centreOnActiveScreen(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main

        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }

        // Never let the window grow taller than the display it lands on.
        var size = window.frame.size
        if size.height > visible.height {
            size.height = visible.height
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        }

        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        )
    }

    private func existingWindow(for controller: AppController) -> NSWindow {
        if let window { return window }

        let hosting = NSHostingController(
            rootView: SettingsView(controller: controller, preferences: controller.preferences)
        )
        let created = NSWindow(contentViewController: hosting)
        created.title = "Whisperoid Settings"
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.setContentSize(hosting.view.fittingSize)

        window = created
        return created
    }
}
