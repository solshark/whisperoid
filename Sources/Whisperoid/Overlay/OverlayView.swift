import AppKit
import SwiftUI

/// The dictation overlay: flowing ribbons with a single line beneath.
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
        VStack(spacing: 14) {
            WavesVisual(levels: model.levels, mode: mode)
            caption
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SoftBackdrop())
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var mode: WavesVisual.Mode {
        switch model.phase {
        case .recording: .listening
        case .transcribing: .working
        case .done, .failed: .settled(since: model.phaseChangedAt)
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch model.phase {
        case .recording:
            Text(Self.timestamp(model.elapsed))
                .font(.system(size: 20, weight: .light, design: .rounded))
                .monospacedDigit()
                .tracking(3)
                .foregroundStyle(.white.opacity(0.78))

        case .transcribing:
            Text("TRANSCRIBING")
                .font(.system(size: 13, weight: .light, design: .rounded))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.7))

        case .done:
            Text(doneSummary)
                .font(.system(size: 15, weight: .light, design: .rounded))
                .monospacedDigit()
                .tracking(2)
                .foregroundStyle(.white.opacity(0.82))

        case .failed:
            Text(model.message)
                .font(.system(size: 13, weight: .light, design: .rounded))
                .foregroundStyle(.orange.opacity(0.95))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 40)
        }
    }

    private var doneSummary: String {
        let language = model.language.isEmpty ? "?" : model.language
        return String(format: "Copied · %@ · %.2f s", language, model.duration)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
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
                .init(color: .black.opacity(0.52), location: 0.0),
                .init(color: .black.opacity(0.40), location: 0.35),
                .init(color: .black.opacity(0.16), location: 0.70),
                .init(color: .clear, location: 1.0),
            ],
            center: .center
        )
        .allowsHitTesting(false)
    }
}
