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
        static let logCleanupComparison = "logCleanupComparison"
        static let cleanupIdleUnloadMinutes = "cleanupIdleUnloadMinutes"
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

    /// Writes the text before and after cleanup to the unified log.
    ///
    /// Off by default and deliberately not sticky-by-accident: entries are
    /// written at public privacy, so anything dictated while this is on is
    /// readable by any process that can read the system log. It exists to make
    /// cleanup quality judgeable during evaluation, not to run permanently.
    var logCleanupComparison: Bool {
        didSet { defaults.set(logCleanupComparison, forKey: Key.logCleanupComparison) }
    }

    /// Minutes of inactivity after which the cleanup model is unloaded.
    ///
    /// Zero keeps it resident. The model holds around 3.5 GB, and reloading it
    /// from a warm cache takes about 3 seconds, so holding it through a long
    /// idle period buys very little on a machine that is doing other work.
    var cleanupIdleUnloadMinutes: Int {
        didSet { defaults.set(cleanupIdleUnloadMinutes, forKey: Key.cleanupIdleUnloadMinutes) }
    }

    static let unloadChoices: [Int] = [1, 2, 5, 10, 30, 0]

    static func unloadTitle(_ minutes: Int) -> String {
        minutes == 0 ? "Never" : "After \(minutes) min"
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
            Key.logCleanupComparison: false,
            Key.cleanupIdleUnloadMinutes: 2,
            Key.cleanupGlossary: ModelOutput.defaultGlossary
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
        logCleanupComparison = defaults.bool(forKey: Key.logCleanupComparison)
        cleanupIdleUnloadMinutes = defaults.integer(forKey: Key.cleanupIdleUnloadMinutes)
    }
}
