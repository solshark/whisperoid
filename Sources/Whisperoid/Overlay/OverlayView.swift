import AppKit
import SwiftUI
import WhisperoidCore

/// The overlay in the style chosen in Settings.
struct OverlayContent: View {

    let model: OverlayModel
    let style: OverlayStyle

    var body: some View {
        switch style {
        case .classic:
            // Light on dark shade whatever the system appearance, which is
            // also what keeps the ribbons in their original colours.
            OverlayView(model: model)
                .environment(\.colorScheme, .dark)
        case .glassCard:
            GlassOverlayView(model: model, layout: .card)
        case .glassPill:
            GlassOverlayView(model: model, layout: .pill)
        }
    }
}

/// The classic dictation overlay: flowing ribbons with a single line beneath.
///
/// Completion is signalled by the ribbons settling to a calm bright line rather
/// than by an icon. A system checkmark clashed badly with the palette and cut
/// the motion dead at the moment it should have been resolving. The transcript
/// preview is deliberately absent too: it is already on the clipboard, and four
/// lines of text needed far more backing than the soft backdrop can give
/// without becoming the panel this was meant to replace.
struct OverlayView: View {

    let model: OverlayModel

    var body: some View {
        VStack(spacing: 16) {
            // Fixed height, or the ribbons expand to fill the panel and push
            // the caption onto the bottom edge — exactly where the elliptical
            // backdrop has already faded to nothing, which is what made the
            // numbers unreadable.
            WavesVisual(levels: model.levels, mode: model.wavesMode)
                .frame(height: 96)
            caption
                .legibleOverAnything()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoftBackdrop())
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    @ViewBuilder
    private var caption: some View {
        switch model.phase {
        case .warmingUp:
            if model.message.isEmpty {
                Text("GETTING READY")
                    .font(.system(size: 15, weight: .light, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.88))
            } else {
                warning(model.message)
            }

        case .recording:
            // A device that has gone silent mid-recording says so in place of
            // the timer, which would otherwise suggest all is well.
            if model.message.isEmpty {
                Text(model.timestamp)
                    .font(.system(size: 23, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                warning(model.message)
            }

        case .transcribing:
            Text("TRANSCRIBING")
                .font(.system(size: 15, weight: .light, design: .monospaced))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.88))

        case .cleaning:
            Text("CLEANING UP")
                .font(.system(size: 15, weight: .light, design: .monospaced))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.88))

        case .done:
            Text(model.doneSummary)
                .font(.system(size: 17, weight: .light, design: .monospaced))
                .monospacedDigit()
                .tracking(2)
                .foregroundStyle(.white.opacity(0.92))

        case .failed:
            warning(model.message)
        }
    }

    /// A failure, or a device that is open but not listening. Three lines is
    /// what the panel holds legibly.
    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .light, design: .monospaced))
            .foregroundStyle(.orange.opacity(0.95))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 40)
    }
}

/// What every style shows, so they differ in look and never in content.
extension OverlayModel {

    var wavesMode: WavesVisual.Mode {
        switch phase {
        case .warmingUp: .working
        case .recording: .listening
        case .transcribing, .cleaning: .working
        case .done, .failed: .settled(since: phaseChangedAt)
        }
    }

    var timestamp: String {
        let whole = Int(elapsed)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    var doneSummary: String {
        let shown = language.isEmpty ? "?" : language
        return String(format: "Copied · %@ · %.2f s", shown, duration)
    }
}

private extension View {
    /// Layered shadows standing in for a text outline, which SwiftUI has no
    /// direct equivalent of. A tight dark shadow reads as a stroke and a wider
    /// soft one lifts the glyphs off whatever is behind, so the caption stays
    /// readable over a bright terminal as well as a dark desktop.
    func legibleOverAnything() -> some View {
        shadow(color: .black.opacity(0.95), radius: 1.5)
            .shadow(color: .black.opacity(0.85), radius: 3)
            .shadow(color: .black.opacity(0.55), radius: 9)
    }
}

/// A soft pool of shade behind the overlay.
///
/// Drawn as a SwiftUI gradient, not masked material. `NSVisualEffectView` is an
/// AppKit view rendering into its own layer, and a SwiftUI `.mask()` does not
/// clip it — the result was an opaque hard-edged rectangle.
///
/// An ellipse rather than a circle, because the panel is far wider than it is
/// tall. Pure shade rather than blur means it is nearly invisible on a dark
/// desktop, where the text is already legible, and darkens only where it is
/// actually needed on a light one.
private struct SoftBackdrop: View {

    var body: some View {
        EllipticalGradient(
            stops: [
                .init(color: .black.opacity(0.58), location: 0.0),
                .init(color: .black.opacity(0.50), location: 0.40),
                .init(color: .black.opacity(0.28), location: 0.72),
                .init(color: .clear, location: 1.0),
            ],
            center: .center
        )
        .allowsHitTesting(false)
    }
}
