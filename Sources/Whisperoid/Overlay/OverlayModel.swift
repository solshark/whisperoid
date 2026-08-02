import Foundation

/// Presentation state for the floating overlay. The controller writes to it and
/// the SwiftUI view observes it; nothing else should hold a reference.
@MainActor
@Observable
final class OverlayModel {

    enum Phase: Equatable {
        case recording
        case transcribing
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
