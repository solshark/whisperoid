import AppKit

/// Audible cues, for when the overlay is not in view.
///
/// These are stock macOS system sounds rather than bundled assets: they are
/// already familiar, already tuned to the user's alert volume, and add nothing
/// to the bundle size.
enum Sounds {

    private static let start = "Tink"
    private static let finished = "Pop"
    private static let failed = "Basso"

    static func playStart() { play(start) }
    static func playFinished() { play(finished) }
    static func playFailed() { play(failed) }

    private static func play(_ name: String) {
        NSSound(named: name)?.play()
    }
}
