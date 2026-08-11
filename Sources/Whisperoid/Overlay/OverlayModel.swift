import Foundation

/// Presentation state for the floating overlay. The controller writes to it and
/// the SwiftUI view observes it; nothing else should hold a reference.
@MainActor
@Observable
final class OverlayModel {

    enum Phase: Equatable {
        /// The device is open but has not produced sound yet. A Bluetooth
        /// headset leaving its music profile takes a moment, and a recording
        /// that looks live during it costs the user their opening words.
        case warmingUp
        case recording
        case transcribing
        /// Only entered when post-processing is switched on. The model mode can
        /// take a couple of seconds from cold, and without its own phase that
        /// time is indistinguishable from a stalled transcription.
        case cleaning
        case done
        case failed
    }

    var phase: Phase = .recording

    /// When the current phase began. The waves ease to rest relative to this,
    /// so completion resolves rather than snapping.
    var phaseChangedAt = Date()

    /// Recent microphone RMS readings, oldest first.
    var levels: [Float] = []
    var elapsed: TimeInterval = 0

    var text = ""
    var language = ""
    var duration: TimeInterval = 0
    var message = ""
}
