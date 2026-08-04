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
        static let cleanupMode = "cleanupMode"
        static let cleanupGlossary = "cleanupGlossary"
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

    /// Post-processing applied to a transcript before it is injected.
    ///
    /// Off by default. Both alternatives can alter what the speaker said, so
    /// neither is turned on for anyone who has not chosen it deliberately.
    var cleanupMode: CleanupMode {
        didSet { defaults.set(cleanupMode.rawValue, forKey: Key.cleanupMode) }
    }

    /// Terms the model should recognise, one per line.
    ///
    /// Exposed because measurement showed the glossary, not the model, is what
    /// makes the model mode work: with no glossary every model tested fixed one
    /// defect in six. Evaluating the feature without being able to edit this
    /// would be evaluating the wrong thing.
    var cleanupGlossary: String {
        didSet { defaults.set(cleanupGlossary, forKey: Key.cleanupGlossary) }
    }

    var glossaryTerms: [String] {
        cleanupGlossary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.playSounds: true,
            Key.autoStopOnSilence: true,
            Key.cleanupMode: CleanupMode.off.rawValue,
            Key.cleanupGlossary: ModelCleaner.Configuration.defaultGlossary
                .joined(separator: "\n"),
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
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .off
        cleanupGlossary = defaults.string(forKey: Key.cleanupGlossary) ?? ""
    }
}
