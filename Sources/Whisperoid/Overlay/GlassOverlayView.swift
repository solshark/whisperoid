import SwiftUI

/// The dictation overlay on a glass surface, in the system's own material.
///
/// Two layouts share it. The card sits in the middle of the screen like the
/// classic overlay, at a fraction of its size. The pill sits below the menu bar
/// holding only small ribbons and the timer or status, and grows into a card
/// when there is a warning to read, since three lines do not fit in a capsule.
///
/// Both are one glass shape whose size changes with the content, rather than
/// separate shapes swapped in and out, so a change of phase resizes the glass
/// instead of cutting to a different panel.
///
/// Text is the system font in sentence case and takes its colour from the
/// appearance, so it reads on light and dark glass without the shadows the
/// classic overlay needs over an unknown background.
struct GlassOverlayView: View {

    enum Layout {
        case card
        case pill
    }

    let model: OverlayModel
    let layout: Layout

    var body: some View {
        surface
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: layout == .pill ? .top : .center
            )
            .animation(.spring(duration: 0.35, bounce: 0.15), value: model.phase)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: model.message)
    }

    /// The pill stays a capsule unless there is a warning to show.
    private var isCompact: Bool {
        layout == .pill && warning == nil
    }

    private var surface: some View {
        Group {
            if isCompact {
                HStack(spacing: 10) {
                    WavesVisual(levels: model.levels, mode: model.wavesMode, lineScale: 0.6)
                        .frame(width: 56, height: 20)
                    status(textSize: 13, timerSize: 14)
                }
            } else {
                VStack(spacing: layout == .pill ? 8 : 12) {
                    WavesVisual(levels: model.levels, mode: model.wavesMode, lineScale: 0.8)
                        .frame(height: layout == .pill ? 28 : 44)
                    if let warning {
                        warningLabel(warning)
                    } else {
                        status(textSize: 15, timerSize: 20)
                    }
                }
            }
        }
        .padding(.horizontal, isCompact ? 16 : 22)
        .padding(.vertical, isCompact ? 0 : 16)
        .frame(height: isCompact ? 36 : nil)
        .frame(width: isCompact ? nil : (layout == .pill ? 340 : 300))
        .glassSurface(cornerRadius: isCompact || layout == .pill ? 18 : 24)
    }

    /// A failure, or a device that is open but not producing sound. Shown in
    /// place of the timer, which would otherwise suggest all is well.
    private var warning: String? {
        switch model.phase {
        case .warmingUp, .recording, .failed:
            model.message.isEmpty ? nil : model.message
        case .transcribing, .cleaning, .done:
            nil
        }
    }

    @ViewBuilder
    private func status(textSize: CGFloat, timerSize: CGFloat) -> some View {
        Group {
            switch model.phase {
            case .warmingUp:
                Text("Getting ready")
            case .recording:
                Text(model.timestamp)
                    .font(.system(size: timerSize, weight: .semibold))
            case .transcribing:
                Text("Transcribing")
            case .cleaning:
                Text("Cleaning up")
            case .done:
                Text(model.doneSummary)
            case .failed:
                Text("Dictation failed")
            }
        }
        .font(.system(size: textSize, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.primary)
        .lineLimit(1)
    }

    private func warningLabel(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// Liquid Glass on macOS 26 and later. Earlier versions get the frosted
    /// material with a hairline edge, which is how floating panels looked there.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        }
    }
}
