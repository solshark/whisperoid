import Foundation
import Observation
import WhisperoidCore

/// User-adjustable settings, persisted in `UserDefaults`.
@MainActor
@Observable
final class Preferences {

    private enum Key {
        static let playSounds = "playSounds"
        static let autoStopOnSilence = "autoStopOnSilence"
        static let silenceSeconds = "silenceSeconds"
        static let silenceDropDecibels = "silenceDropDecibels"
    }

    static let silenceRange: ClosedRange<Double> = 1.5...10.0

    /// Below about 15 dB, gaps within normal speech are misread as silence.
    /// Above about 25 dB, the threshold falls under a typical room's noise
    /// floor and auto-stop stops firing at all. The range spans both edges so
    /// the effect is visible while tuning.
    static let dropRange: ClosedRange<Double> = 10...30

    private let defaults: UserDefaults

    var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds) }
    }

    var autoStopOnSilence: Bool {
        didSet { defaults.set(autoStopOnSilence, forKey: Key.autoStopOnSilence) }
    }

    var silenceSeconds: Double {
        didSet {
            let clamped = min(max(silenceSeconds, Self.silenceRange.lowerBound), Self.silenceRange.upperBound)
            if clamped != silenceSeconds {
                silenceSeconds = clamped
                return
            }
            defaults.set(silenceSeconds, forKey: Key.silenceSeconds)
        }
    }

    var silenceDropDecibels: Double {
        didSet {
            let clamped = min(max(silenceDropDecibels, Self.dropRange.lowerBound), Self.dropRange.upperBound)
            if clamped != silenceDropDecibels {
                silenceDropDecibels = clamped
                return
            }
            defaults.set(silenceDropDecibels, forKey: Key.silenceDropDecibels)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.playSounds: true,
            Key.autoStopOnSilence: true,
            // Measured gaps within continuous speech reach 1.9 s, so 3 s leaves
            // little margin. Auto-stop is a safety net rather than the primary
            // way to finish, so a longer wait costs nothing.
            Key.silenceSeconds: 4.0,
            Key.silenceDropDecibels: Double(SilenceDetector.defaultDropDecibels),
        ])
        playSounds = defaults.bool(forKey: Key.playSounds)
        autoStopOnSilence = defaults.bool(forKey: Key.autoStopOnSilence)
        silenceSeconds = defaults.double(forKey: Key.silenceSeconds)
        silenceDropDecibels = defaults.double(forKey: Key.silenceDropDecibels)
    }
}
