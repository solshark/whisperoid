import AppKit

/// Borderless HUD panel for the dictation overlay.
///
/// It must never become key or main. Taking focus would pull it away from
/// whatever the user is about to paste into, and would also dismiss menus and
/// popovers in the frontmost application. Mouse events pass straight through,
/// so the panel behaves purely as an indicator.
final class OverlayPanel: NSPanel {

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
