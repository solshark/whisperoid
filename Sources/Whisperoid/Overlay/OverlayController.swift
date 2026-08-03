import AppKit
import SwiftUI

/// Owns the overlay panel: creation, placement, phase-driven sizing and fade-out.
@MainActor
final class OverlayController {

    let model = OverlayModel()

    private static let size = NSSize(width: 560, height: 220)

    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    /// Bumped whenever a pending dismissal is called off. A fade-out that is
    /// already running cannot be cancelled, so its completion handler carries
    /// the generation it started in and does nothing if the overlay has been
    /// shown again since.
    private var generation = 0

    func present(_ phase: OverlayModel.Phase) {
        cancelDismissal()

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
        cancelDismissal()
        setPhase(phase)
    }

    /// Calls off any pending dismissal, including a fade already in flight.
    private func cancelDismissal() {
        dismissTask?.cancel()
        dismissTask = nil
        generation &+= 1
    }

    /// Records when the phase began so the ribbons can ease to rest from it.
    private func setPhase(_ phase: OverlayModel.Phase) {
        model.phase = phase
        model.phaseChangedAt = Date()
    }

    func dismiss(after seconds: Double) {
        cancelDismissal()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hideImmediately() {
        dismissTask?.cancel()
        dismissTask = nil
        teardown()
    }

    /// Destroys the panel rather than merely ordering it out.
    ///
    /// `orderOut(_:)` leaves the hosting view and its SwiftUI graph alive, and
    /// `TimelineView(.animation)` in the ribbons keeps asking for a frame on
    /// every display cycle whether or not the window is on screen. A hidden
    /// overlay therefore redrew at the refresh rate for as long as the app was
    /// running: roughly a tenth of a core, permanently, drawing nothing anyone
    /// could see.
    ///
    /// It also made the app far more likely to hit the Swift runtime fault in
    /// `swift_task_isCurrentExecutor`, because the isolation check on the
    /// TimelineView content closure ran millions of times a day while idle.
    private func teardown() {
        guard let panel else { return }
        panel.orderOut(nil)
        // Releases the SwiftUI view graph. Without this the hosting view
        // survives inside the window and keeps its display link alive.
        panel.contentView = nil
        self.panel = nil
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
        let generation = self.generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Untyped AppKit callback: enter the actor rather than assert that
            // we are already on it.
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.teardown()
            }
        }
    }
}
