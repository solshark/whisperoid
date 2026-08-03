import Foundation
import Testing

@testable import WhisperoidCore

/// Auto-stop is the setting most likely to be tuned, and the one where a
/// regression is least visible: a threshold that never arms simply means the
/// recording runs until it is stopped by hand, which reads as a hotkey problem
/// rather than a detector problem.
struct SilenceDetectorTests {

    /// A level well above the speech floor of -50 dBFS.
    private static let speech: Float = 0.05      // about -26 dBFS
    private static let silence: Float = 0.0005   // about -66 dBFS

    private func detector(requiredSilence: TimeInterval = 3) -> SilenceDetector {
        SilenceDetector(requiredSilence: requiredSilence)
    }

    @Test("Nothing is treated as silence before any speech is heard")
    func doesNotArmBeforeSpeech() {
        let detector = detector()
        let start = Date()

        // A long stretch of quiet before the first word must not stop anything.
        for second in 0..<10 {
            let stop = detector.update(level: Self.silence, now: start.addingTimeInterval(Double(second)))
            #expect(stop == false)
        }
        #expect(detector.currentThreshold == nil)
    }

    @Test("A threshold is derived once speech has been heard")
    func armsAfterSpeech() {
        let detector = detector()
        _ = detector.update(level: Self.speech)
        #expect(detector.currentThreshold != nil)
    }

    @Test("Silence for the required duration stops the recording")
    func firesAfterRequiredSilence() {
        let detector = detector(requiredSilence: 3)
        let start = Date()

        #expect(detector.update(level: Self.speech, now: start) == false)
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(0.1)) == false)
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(2.9)) == false)
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(3.2)) == true)
    }

    @Test("Speech during a pause restarts the silence timer")
    func speechResetsTheTimer() {
        let detector = detector(requiredSilence: 3)
        let start = Date()

        _ = detector.update(level: Self.speech, now: start)
        _ = detector.update(level: Self.silence, now: start.addingTimeInterval(0.1))

        // A word two seconds in must push the deadline out, not be ignored.
        _ = detector.update(level: Self.speech, now: start.addingTimeInterval(2.0))

        // The silence clock restarts here, at 4.0, so the stop lands three
        // seconds after that rather than three seconds after the first pause.
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(4.0)) == false)
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(6.5)) == false)
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(7.1)) == true)
    }

    /// A 2 s auto-stop cut speech off mid-sentence in real use; the longest gap
    /// measured within continuous speech at the 20 dB default was 1.9 s. This
    /// pins that relationship so a change to the default cannot silently
    /// reintroduce it.
    @Test("A 1.9 s gap within speech does not trigger a 3 s auto-stop")
    func doesNotFireOnAMeasuredWithinSpeechGap() {
        let detector = detector(requiredSilence: 3)
        let start = Date()

        _ = detector.update(level: Self.speech, now: start)
        _ = detector.update(level: Self.silence, now: start.addingTimeInterval(0.05))
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(1.9)) == false)
    }

    @Test("The threshold stays within its floor and ceiling")
    func thresholdIsBounded() {
        let shouted = detector()
        _ = shouted.update(level: 1.0)  // 0 dBFS
        // Without a ceiling, 0 - 20 = -20 dBFS would sit inside normal speech.
        #expect((shouted.currentThreshold ?? 0) <= -35)

        let faint = detector()
        _ = faint.update(level: 0.003)  // about -50 dBFS, just at the speech floor
        #expect((faint.currentThreshold ?? 0) >= -65)
    }

    @Test("Reset clears both the peak and the pending silence")
    func resetClearsState() {
        let detector = detector(requiredSilence: 3)
        let start = Date()

        _ = detector.update(level: Self.speech, now: start)
        _ = detector.update(level: Self.silence, now: start.addingTimeInterval(0.1))
        detector.reset()

        #expect(detector.currentThreshold == nil)
        // The pending silence must not carry over into the next recording.
        #expect(detector.update(level: Self.silence, now: start.addingTimeInterval(10)) == false)
    }

    @Test("Silent input reports negative infinity rather than a finite value")
    func decibelsFromZero() {
        #expect(SilenceDetector.decibels(from: 0) == -.infinity)
        #expect(SilenceDetector.decibels(from: 1) == 0)
    }
}
