import AppKit
import SwiftUI

/// Owns a plain `NSWindow` hosting a SwiftUI view.
///
/// Windows are managed directly rather than through SwiftUI scenes. Neither
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))` nor `SettingsLink`
/// opens a `Settings` scene from a `MenuBarExtra` using the `.menu` style; both
/// fail silently, because the menu is rendered as a native NSMenu and the
/// SwiftUI activation machinery is not in the responder chain.
///
/// The activation and placement handling here is shared deliberately: getting it
/// wrong produces a window that is genuinely open but invisible to the user, and
/// that is indistinguishable from the menu item doing nothing at all.
@MainActor
final class HostedWindowController<Content: View>: NSObject, NSWindowDelegate {

    private let windowTitle: String
    private let diagnosticName: String
    private let content: @MainActor () -> Content

    private var window: NSWindow?

    init(
        title: String,
        diagnosticName: String,
        content: @escaping @MainActor () -> Content
    ) {
        self.windowTitle = title
        self.diagnosticName = diagnosticName
        self.content = content
        super.init()
    }

    func show() {
        let window = existingWindow()

        // The app runs as an accessory so it has no Dock icon, but an accessory
        // cannot reliably take key focus, and controls such as the shortcut
        // recorders are useless without it. Becoming a regular app for as long
        // as a window is open gives normal activation, at the cost of a
        // temporary Dock icon.
        NSApp.setActivationPolicy(.regular)

        // The policy change needs a runloop turn before activation will take
        // effect. Activating in the same turn leaves the window visible but
        // unfocused and behind the frontmost application.
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
            Log.info("\(self.diagnosticName) visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "policy=\(NSApp.activationPolicy() == .regular ? "regular" : "accessory") "
                + "active=\(NSApp.isActive) "
                + "frame=\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY)) "
                + "level=\(window.level.rawValue) onScreen=\(window.isOnActiveSpace)")
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Only drop back to accessory once nothing of ours is still open, or
        // closing one window would remove the Dock icon while another remains.
        let closing = notification.object as? NSWindow
        let othersVisible = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !othersVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Centres on the display holding the pointer.
    ///
    /// `NSWindow.center()` uses the main screen, which on a multi-display setup
    /// routinely places the window on a monitor the user is not looking at.
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

    private func existingWindow() -> NSWindow {
        if let window { return window }

        let hosting = NSHostingController(rootView: content())
        let created = NSWindow(contentViewController: hosting)
        created.title = windowTitle
        created.styleMask = [.titled, .closable]
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.setContentSize(hosting.view.fittingSize)

        window = created
        return created
    }
}
