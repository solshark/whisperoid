import Foundation
import Testing
import WhisperKit

@testable import WhisperoidCore

/// Whisper invents text, most often "Thank you.", from audio with no speech in
/// it. Each segment it returns carries the time it covers, and these check
/// that a segment during which nothing was audible is left out, while
/// anything that was audible, however quietly, is kept.
struct UnheardSegmentTests {

    private static let sampleRate: Float = 16000

    /// `seconds` of speech-like signal at `speech` dBFS, then `silence`
    /// seconds of room noise 20 dB below it, as a dictation ends before the
    /// recording stops.
    private func recording(speech: Float = -20, seconds: Float = 6, silence: Float = 1.5) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int((seconds + silence) * Self.sampleRate)).map { index in
            let time = Float(index) / Self.sampleRate
            let level: Float
            if time >= seconds {
                level = speech - 20
            } else {
                let syllable = time.truncatingRemainder(dividingBy: 0.3) < 0.2
                level = syllable ? speech : speech - 12
            }
            // Uniform noise in ±a has RMS a/√3.
            let amplitude = pow(10, level / 20) * Float(3).squareRoot()
            return Float.random(in: -amplitude...amplitude, using: &generator)
        }
    }

    private func segment(_ start: Float, _ end: Float, _ text: String) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text)
    }

    private func result(_ text: String, _ segments: [TranscriptionSegment]) -> TranscriptionResult {
        TranscriptionResult(text: text, segments: segments, language: "en", timings: TranscriptionTimings())
    }

    @Test("Text invented in the silence after the last words is left out")
    func dropsTrailingInvention() {
        let audio = recording()
        let piece = result("So that's not a big deal. Thank you.", [
            segment(0, 6, " So that's not a big deal."),
            segment(6.0, 7.5, " Thank you."),
        ])

        let heard = Transcriber.heardText(of: [piece], in: audio,
                                          pauseThreshold: Transcriber.pauseThreshold(for: audio))

        #expect(heard.text == "So that's not a big deal.")
        #expect(heard.unheardSegments == 1)
    }

    @Test("A piece with nothing left out keeps WhisperKit's text unchanged")
    func keepsWholePieceVerbatim() {
        let audio = recording()
        // Deliberately not the segments joined, to show which one is used.
        let piece = result("WhisperKit's own text.", [
            segment(0, 3, " So that's"),
            segment(3, 6, " not a big deal."),
        ])

        let heard = Transcriber.heardText(of: [piece], in: audio,
                                          pauseThreshold: Transcriber.pauseThreshold(for: audio))

        #expect(heard.text == "WhisperKit's own text.")
        #expect(heard.unheardSegments == 0)
    }

    @Test("Pieces are joined with one space when one of them is left out entirely")
    func joinsRemainingPieces() {
        let audio = recording(seconds: 6, silence: 3)
        let pieces = [
            result("First piece.", [segment(0, 6, " First piece.")]),
            result("Thank you.", [segment(6.2, 9, " Thank you.")]),
        ]

        let heard = Transcriber.heardText(of: pieces, in: audio,
                                          pauseThreshold: Transcriber.pauseThreshold(for: audio))

        #expect(heard.text == "First piece.")
        #expect(heard.unheardSegments == 1)
    }

    @Test("Quiet speech is heard at any input level", arguments: [Float(-15), -45, -70])
    func hearsQuietSpeech(speech: Float) {
        let audio = recording(speech: speech)
        let threshold = Transcriber.pauseThreshold(for: audio)

        #expect(Transcriber.isHeard(segment(0, 6, " Words."), in: audio, pauseThreshold: threshold))
        #expect(!Transcriber.isHeard(segment(6.0, 7.5, " Thank you."), in: audio, pauseThreshold: threshold))
    }

    @Test("One audible moment is enough to keep a segment")
    func keepsSegmentReachingIntoSpeech() {
        // Mostly silence, but its first 200 ms overlap the end of speech: a
        // short word whose timestamps were placed late.
        let audio = recording()
        let threshold = Transcriber.pauseThreshold(for: audio)

        #expect(Transcriber.isHeard(segment(5.8, 7.5, " Yes."), in: audio, pauseThreshold: threshold))
    }

    @Test("A segment whose timestamps collapsed to an instant is judged by the sound there")
    func judgesInstantBySound() {
        let audio = recording()
        let threshold = Transcriber.pauseThreshold(for: audio)

        #expect(Transcriber.isHeard(segment(3, 3, " Yes."), in: audio, pauseThreshold: threshold))
        #expect(!Transcriber.isHeard(segment(7, 7, " Yes."), in: audio, pauseThreshold: threshold))
    }

    @Test("A segment placed after the recording ended is left out")
    func dropsSegmentBeyondEnd() {
        let audio = recording()

        #expect(!Transcriber.isHeard(segment(9, 12, " Thank you."), in: audio,
                                     pauseThreshold: Transcriber.pauseThreshold(for: audio)))
    }
}
