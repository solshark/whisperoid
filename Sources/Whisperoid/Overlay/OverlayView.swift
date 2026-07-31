import AppKit
import SwiftUI

struct OverlayView: View {

    let model: OverlayModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(HUDBackground())
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.18), value: model.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 16) {
                WaveformView(levels: model.levels)
                Spacer(minLength: 8)
                Text(Self.timestamp(model.elapsed))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

        case .transcribing:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

        case .done:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(doneSummary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(model.text)
                    .font(.system(size: 14))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }

        case .failed:
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(model.message)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
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

/// Live microphone trace. Levels arrive oldest first and scroll leftwards.
private struct WaveformView: View {

    let levels: [Float]

    private static let barCount = 48
    private static let barWidth: CGFloat = 3
    private static let maximumHeight: CGFloat = 30
    private static let minimumHeight: CGFloat = 3

    var body: some View {
        let shown = Array(levels.suffix(Self.barCount))
        let leadingGap = Self.barCount - shown.count

        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                let level = index < leadingGap ? 0 : shown[index - leadingGap]
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: Self.barWidth, height: Self.height(for: level))
            }
        }
        .frame(height: Self.maximumHeight)
        .animation(.linear(duration: 0.08), value: levels)
    }

    private static func height(for rms: Float) -> CGFloat {
        minimumHeight + CGFloat(normalised(rms)) * (maximumHeight - minimumHeight)
    }

    /// Maps RMS onto 0...1 across a 60 dB range. A linear mapping spends almost
    /// all of its range on levels far louder than speech, which reads as a flat
    /// line at normal talking volume.
    private static func normalised(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }
}

/// Native macOS HUD material. SwiftUI's `glassEffect` is not available on macOS
/// in the current SDK, and this is what system HUDs use in any case.
private struct HUDBackground: NSViewRepresentable {

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
