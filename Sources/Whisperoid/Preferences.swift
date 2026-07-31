import Foundation
import Observation

/// User-adjustable settings, persisted in `UserDefaults`.
@MainActor
@Observable
final class Preferences {

    private enum Key {
        static let playSounds = "playSounds"
        static let autoStopOnSilence = "autoStopOnSilence"
        static let silenceSeconds = "silenceSeconds"
    }

    static let silenceRange: ClosedRange<Double> = 1.5...10.0

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.playSounds: true,
            Key.autoStopOnSilence: true,
            Key.silenceSeconds: 3.0,
        ])
        playSounds = defaults.bool(forKey: Key.playSounds)
        autoStopOnSilence = defaults.bool(forKey: Key.autoStopOnSilence)
        silenceSeconds = defaults.double(forKey: Key.silenceSeconds)
    }
}
