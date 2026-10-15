import Foundation
import Testing
import WhisperKit

@testable import WhisperoidCore

/// Recordings longer than 30 s are split at pauses before transcription, and a
/// split that lands inside speech loses words: the piece that starts
/// mid-sentence decodes badly or not at all. These drive WhisperKit's own
/// chunker with a synthetic dictation, so where the cut lands is checked
/// without loading the model.
struct PauseDetectionTests {

    private static let sampleRate: Float = 16000

    /// 50 s of speech-like signal with 3 s pauses at 17–20 s and 37–40 s.
    ///
    /// Speech alternates 200 ms at `speech` dBFS RMS with 100 ms 12 dB below
    /// it, as syllables and the gaps between them do; pauses are room noise at
    /// `pause` dBFS. The first window spans 0–30 s and the chunker looks for its
    /// cut in 15–30 s, where the only real pause is 17–20 s.
    private func dictation(speech: Float, pause: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        let pauses: [ClosedRange<Float>] = [17...20, 37...40]
        return (0..<Int(50 * Self.sampleRate)).map { index in
            let time = Float(index) / Self.sampleRate
            let level: Float
            if pauses.contains(where: { $0.contains(time) }) {
                level = pause
            } else {
                let syllable = time.truncatingRemainder(dividingBy: 0.3) < 0.2
                level = syllable ? speech : speech - 12
            }
            // Uniform noise in ±a has RMS a/√3.
            let amplitude = pow(10, level / 20) * Float(3).squareRoot()
            return Float.random(in: -amplitude...amplitude, using: &generator)
        }
    }

    private func firstCut(_ audio: [Float], threshold: Float) async throws -> Float {
        let chunks = try await VADAudioChunker(vad: EnergyVAD(energyThreshold: threshold))
            .chunkAll(audioArray: audio, maxChunkLength: 480_000, decodeOptions: DecodingOptions())
        try #require(chunks.count > 1)
        return Float(chunks[1].seekOffsetIndex) / Self.sampleRate
    }

    @Test("The cut lands in the pause at any input level", arguments: [
        (speech: Float(-15), pause: Float(-30)),  // hot headset, pauses above -34 dBFS
        (speech: Float(-33), pause: Float(-55)),  // typical headset
        (speech: Float(-45), pause: Float(-65)),  // webcam microphone
        (speech: Float(-60), pause: Float(-80)),  // very quiet
    ])
    func cutsInPause(speech: Float, pause: Float) async throws {
        let audio = dictation(speech: speech, pause: pause)
        let cut = try await firstCut(audio, threshold: Transcriber.pauseThreshold(for: audio))
        #expect((17...20).contains(cut), "cut at \(cut) s")
    }

    /// The failure this replaces, kept as a record of it. If WhisperKit's
    /// default ever changes, this test failing says so.
    @Test("The fixed default cuts through speech at both ends of the range")
    func defaultCutsThroughSpeech() async throws {
        let quiet = dictation(speech: -45, pause: -65)
        #expect(try await firstCut(quiet, threshold: 0.02) == 22.5)

        let hot = dictation(speech: -15, pause: -30)
        #expect(try await firstCut(hot, threshold: 0.02) == 30)
    }

    @Test("The threshold follows the recording's level")
    func thresholdScalesWithLevel() {
        let audio = dictation(speech: -45, pause: -65)
        let louder = audio.map { $0 * 10 }
        let ratio = Transcriber.pauseThreshold(for: louder) / Transcriber.pauseThreshold(for: audio)
        #expect(abs(ratio - 10) < 0.01)
    }

    // MARK: - Levelling

    private func decibels(_ value: Float) -> Float { 20 * log10(value) }

    private func loudPeak(_ samples: [Float]) -> Float {
        let peaks = Transcriber.frameLevels(samples).map(\.peak).sorted()
        return peaks[peaks.count * 99 / 100]
    }

    /// The synthetic signal's peaks are only 4.8 dB above its RMS, where real
    /// speech runs 15–20 dB, so -30 dBFS here needs about the +22 dB a webcam
    /// microphone peaking near -23 dBFS needs in practice.
    @Test("Quiet speech is raised so its loud end sits at -3 dBFS")
    func raisesQuietSpeech() {
        let audio = dictation(speech: -30, pause: -50)
        let result = Transcriber.levelled(audio)
        #expect(abs(decibels(loudPeak(result.samples)) - -3) < 0.5)
        #expect(result.gainDecibels > 20)
    }

    /// Peaks above full scale, as captured from a headset that logged
    /// +2.9 dBFS.
    @Test("Hot input is brought down, not left clipping")
    func lowersHotInput() {
        let audio = dictation(speech: -2, pause: -25)
        let result = Transcriber.levelled(audio)
        #expect(result.gainDecibels < 0)
        #expect(abs(decibels(loudPeak(result.samples)) - -3) < 0.5)
    }

    @Test("Near-silence is not amplified beyond +30 dB")
    func capsGain() {
        let audio = dictation(speech: -85, pause: -100)
        let result = Transcriber.levelled(audio)
        #expect(abs(result.gainDecibels - 30) < 0.1)
    }

    @Test("Digital silence passes through untouched")
    func leavesSilence() {
        let silence = [Float](repeating: 0, count: 32000)
        let result = Transcriber.levelled(silence)
        #expect(result.gainDecibels == 0)
        #expect(result.samples == silence)
    }

    @Test("One click does not hold the rest of the recording down")
    func ignoresClick() {
        var audio = dictation(speech: -40, pause: -60)
        audio[400_000] = 1.0
        let result = Transcriber.levelled(audio)
        #expect(result.gainDecibels > 20)
    }
}
