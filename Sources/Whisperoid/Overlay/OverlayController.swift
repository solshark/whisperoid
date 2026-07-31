import AppKit
import SwiftUI

/// Owns the overlay panel: creation, placement, phase-driven sizing and fade-out.
@MainActor
final class OverlayController {

    let model = OverlayModel()

    private static let width: CGFloat = 440
    private static let compactHeight: CGFloat = 72
    private static let expandedHeight: CGFloat = 96

    /// Distance from the bottom of the active screen's visible area.
    private static let bottomInset: CGFloat = 96

    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func present(_ phase: OverlayModel.Phase) {
        dismissTask?.cancel()
        dismissTask = nil

        model.phase = phase

        let panel = existingPanel()
        resize(panel, for: phase)
        place(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
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
        model.phase = phase
        resize(panel, for: phase)
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

        let created = OverlayPanel(
            contentSize: NSSize(width: Self.width, height: Self.compactHeight)
        )
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = NSRect(origin: .zero, size: created.frame.size)
        hosting.autoresizingMask = [.width, .height]
        created.contentView = hosting

        panel = created
        return created
    }

    private func resize(_ panel: OverlayPanel, for phase: OverlayModel.Phase) {
        let height = phase == .done ? Self.expandedHeight : Self.compactHeight
        guard panel.frame.height != height else { return }

        // Grow upwards so the bottom edge stays put.
        var frame = panel.frame
        frame.origin.y -= height - frame.height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func place(_ panel: OverlayPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.bottomInset
            )
        )
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: {
            // AppKit invokes this on the main thread; the signature is untyped.
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}
