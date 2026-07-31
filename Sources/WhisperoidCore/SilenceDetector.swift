import Foundation

/// Decides when a recording has gone quiet long enough to stop on its own.
///
/// The silence threshold is derived from the loudest speech heard during the
/// current recording rather than fixed in dBFS. Absolute levels depend entirely
/// on microphone gain: measured speech on one machine peaked at -37 dBFS, which
/// is below what a naive absolute threshold would treat as silence, so a fixed
/// value classified 92% of active speech as silent.
///
/// Auto-stop only arms once speech has actually been heard. Without that guard
/// it would fire during the pause between pressing the hotkey and starting to
/// speak, ending the recording before a word is said.
public final class SilenceDetector {

    /// How far below the loudest speech so far a level must fall to count as
    /// silence.
    ///
    /// Measured against two real recordings: at 15 dB the longest gap within
    /// continuous speech was 3.4-3.8 s, which false-triggers a 3 s auto-stop.
    /// At 20 dB it falls to 1.9 s on both. Beyond 25 dB the threshold drops
    /// below the room's noise floor and auto-stop stops firing entirely.
    public static let defaultDropDecibels: Float = 20

    /// Bounds on the derived threshold. The ceiling stops a shout from pushing
    /// the threshold up into normal speech; the floor stops a near-silent room
    /// from pushing it down into the noise floor.
    private static let thresholdFloor: Float = -65
    private static let thresholdCeiling: Float = -35

    /// The peak must reach this before auto-stop arms. Below it, nothing has
    /// been heard that could reasonably be called speech.
    private static let speechFloor: Float = -50

    public let dropDecibels: Float
    public let requiredSilence: TimeInterval

    private var peakDecibels: Float = -.infinity
    private var silentSince: Date?

    public init(
        dropDecibels: Float = SilenceDetector.defaultDropDecibels,
        requiredSilence: TimeInterval
    ) {
        self.dropDecibels = dropDecibels
        self.requiredSilence = requiredSilence
    }

    /// The threshold currently in force, or nil before any speech is heard.
    public var currentThreshold: Float? {
        guard peakDecibels >= Self.speechFloor else { return nil }
        return min(max(peakDecibels - dropDecibels, Self.thresholdFloor), Self.thresholdCeiling)
    }

    public var observedPeak: Float { peakDecibels }

    public func reset() {
        peakDecibels = -.infinity
        silentSince = nil
    }

    /// Feeds one level reading. Returns `true` when the recording should stop.
    public func update(level rms: Float, now: Date = Date()) -> Bool {
        let decibels = Self.decibels(from: rms)
        peakDecibels = max(peakDecibels, decibels)

        guard let threshold = currentThreshold else {
            // No speech heard yet, so silence is not meaningful.
            return false
        }

        guard decibels < threshold else {
            silentSince = nil
            return false
        }

        guard let since = silentSince else {
            silentSince = now
            return false
        }
        return now.timeIntervalSince(since) >= requiredSilence
    }

    public static func decibels(from rms: Float) -> Float {
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }
}
