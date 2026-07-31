import Foundation

/// Decides when a recording has gone quiet long enough to stop on its own.
///
/// Auto-stop only arms once speech has actually been heard. Without that guard
/// it would fire during the pause between pressing the hotkey and starting to
/// speak, ending the recording before a word is said.
public final class SilenceDetector {

    /// Level below which audio counts as silence, in dBFS. Normal speech sits
    /// around -40 to -15 dBFS; room tone is usually below -50.
    public static let defaultThresholdDecibels: Float = -42

    public let thresholdDecibels: Float
    public let requiredSilence: TimeInterval

    private var hasHeardSpeech = false
    private var silentSince: Date?

    public init(
        thresholdDecibels: Float = SilenceDetector.defaultThresholdDecibels,
        requiredSilence: TimeInterval
    ) {
        self.thresholdDecibels = thresholdDecibels
        self.requiredSilence = requiredSilence
    }

    public func reset() {
        hasHeardSpeech = false
        silentSince = nil
    }

    /// Feeds one level reading. Returns `true` when the recording should stop.
    public func update(level rms: Float, now: Date = Date()) -> Bool {
        let decibels = Self.decibels(from: rms)

        guard decibels >= thresholdDecibels else {
            // Quiet. Only meaningful once speech has been heard at least once.
            guard hasHeardSpeech else { return false }
            guard let since = silentSince else {
                silentSince = now
                return false
            }
            return now.timeIntervalSince(since) >= requiredSilence
        }

        hasHeardSpeech = true
        silentSince = nil
        return false
    }

    public static func decibels(from rms: Float) -> Float {
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }
}
