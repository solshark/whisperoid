import AppKit
import SwiftUI

/// Owns the overlay panel: creation, placement, phase-driven sizing and fade-out.
@MainActor
final class OverlayController {

    let model = OverlayModel()

    private static let size = NSSize(width: 560, height: 220)

    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func present(_ phase: OverlayModel.Phase) {
        dismissTask?.cancel()
        dismissTask = nil

        setPhase(phase)

        let panel = existingPanel()
        place(panel)

        // Reveal over a couple of frames rather than instantly. The window's
        // backing store still holds the last frame it drew, so showing it at
        // full opacity flashes the previous result before SwiftUI redraws.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Updates the phase of an already visible panel without re-placing it, so
    /// the overlay does not jump if the pointer has moved to another screen.
    func update(_ phase: OverlayModel.Phase) {
        guard let panel, panel.isVisible else {
            present(phase)
            return
        }
        dismissTask?.cancel()
        dismissTask = nil
        setPhase(phase)
    }

    /// Records when the phase began so the ribbons can ease to rest from it.
    private func setPhase(_ phase: OverlayModel.Phase) {
        model.phase = phase
        model.phaseChangedAt = Date()
    }

    func dismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hideImmediately() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel lifecycle

    private func existingPanel() -> OverlayPanel {
        if let panel { return panel }

        let created = OverlayPanel(contentSize: Self.size)
        // No window shadow: it would outline an invisible rectangle around a
        // graphic that has no panel behind it.
        created.hasShadow = false
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = NSRect(origin: .zero, size: created.frame.size)
        hosting.autoresizingMask = [.width, .height]
        created.contentView = hosting

        panel = created
        return created
    }

    private func place(_ panel: OverlayPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        )
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: {
            // Untyped AppKit callback: enter the actor rather than assert that
            // we are already on it.
            Task { @MainActor in panel.orderOut(nil) }
        }
    }
}
