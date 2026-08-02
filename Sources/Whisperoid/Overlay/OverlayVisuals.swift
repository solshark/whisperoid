import SwiftUI

/// Maps microphone RMS onto 0...1 across a 60 dB range.
///
/// A linear mapping spends nearly all of its range on volumes far louder than
/// speech, so everything sits near zero and the animation looks dead.
enum LevelScale {

    static func normalised(_ rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return Double(min(1, max(0, (decibels + 60) / 60)))
    }

    /// Mean of the most recent readings, which stops the visuals juddering
    /// between tap callbacks.
    static func smoothed(_ levels: [Float], window: Int = 5) -> Double {
        let recent = levels.suffix(window)
        guard !recent.isEmpty else { return 0 }
        return recent.map(normalised).reduce(0, +) / Double(recent.count)
    }
}

extension Color {
    static let auroraCore = Color(red: 0.62, green: 0.55, blue: 1.00)
    static let auroraEdge = Color(red: 0.35, green: 0.30, blue: 0.86)
    static let auroraAccent = Color(red: 0.45, green: 0.85, blue: 1.00)
}

/// Layered sine ribbons whose amplitude follows the voice.
struct WavesVisual: View {

    enum Mode: Equatable {
        /// Amplitude tracks the microphone.
        case listening
        /// Voice is finished; a band sweeps the ribbons to show work happening.
        case working
        /// Transcription complete. The ribbons ease down to a calm bright line,
        /// which is the completion signal — there is no separate icon, so the
        /// motion resolves instead of being cut off.
        case settled(since: Date)
    }

    let levels: [Float]
    var mode: Mode = .listening

    private static let layers = 4

    /// Near-flat at rest so silence is unmistakable, and a large multiplier so
    /// speech is dramatic. A high resting baseline made quiet and loud look
    /// almost identical.
    private static let restingAmplitude = 0.055
    private static let voiceAmplitude = 1.25

    /// How long the ribbons take to come to rest once transcription finishes.
    private static let settleSeconds = 0.9

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date
            let time = now.timeIntervalSinceReferenceDate

            // How far through the settling motion, 1 at the moment of
            // completion easing to 0 as the ribbons come to rest.
            let settling: Double = {
                guard case .settled(let since) = mode else { return 0 }
                let elapsed = now.timeIntervalSince(since)
                return max(0, 1 - elapsed / Self.settleSeconds)
            }()

            let level: Double = {
                switch mode {
                case .listening: LevelScale.smoothed(levels)
                case .working: 0
                case .settled: settling * 0.45
                }
            }()

            Canvas { canvas, size in
                let midline = size.height / 2
                // Sweeps left to right on repeat while transcribing.
                let sweep = (time * 0.9).truncatingRemainder(dividingBy: 1)

                for layer in 0..<Self.layers {
                    let ratio = Double(layer) / Double(Self.layers)
                    let reach = Self.restingAmplitude + level * Self.voiceAmplitude
                    let amplitude = size.height * 0.30 * reach * (1 - ratio * 0.55)
                    let frequency = 1.6 + ratio * 1.5
                    // Faster than a plain sine, and speech speeds it up further
                    // so the response is felt as well as seen. Settling slows.
                    let settleEase = mode.isSettled ? 0.35 + settling * 0.65 : 1
                    let speed = (1.7 + ratio * 1.1) * (1 + level * 0.9) * settleEase
                    // Brightens as it comes to rest, so stillness reads as
                    // completion rather than as the animation having stopped.
                    let restGlow = mode.isSettled ? 0.55 + (1 - settling) * 0.45 : 0.55 + level * 0.45
                    let opacity = (0.9 - ratio * 0.6) * restGlow

                    var path = Path()
                    let step: CGFloat = 3
                    var x: CGFloat = 0
                    while x <= size.width {
                        let progress = Double(x / size.width)
                        // Tapered at both ends so the ribbon does not appear to
                        // be clipped by an invisible window edge.
                        let envelope = sin(progress * .pi)

                        var displacement = sin(progress * frequency * 2 * .pi + time * speed)
                        if mode == .working {
                            // A narrow travelling bulge, so the shape is
                            // obviously being processed rather than listening.
                            let distance = abs(progress - sweep)
                            let band = exp(-pow(distance * 7, 2))
                            displacement *= 0.25 + band * 2.6
                        }

                        let y = midline + displacement * amplitude * envelope
                        if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                        x += step
                    }

                    canvas.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color.auroraEdge.opacity(0),
                                Color.auroraAccent.opacity(opacity),
                                Color.auroraCore.opacity(opacity),
                                Color.auroraEdge.opacity(0),
                            ]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: 0)
                        ),
                        style: StrokeStyle(lineWidth: 2.6 - ratio, lineCap: .round)
                    )
                }
            }
        }
    }
}

private extension WavesVisual.Mode {
    var isSettled: Bool {
        if case .settled = self { return true }
        return false
    }
}
