import AVFoundation
import Testing

@testable import WhisperoidCore

/// Covers the conversion path that crashed the application seven times.
///
/// The tap is fed buffers directly rather than through real hardware, which is
/// what makes the interesting case testable at all: a recording that begins in
/// one hardware format and continues in another cannot be produced on demand
/// from a microphone, but it is exactly what happens when a Bluetooth headset
/// disconnects.
struct AudioRecorderTests {

    /// 1 channel at 24 kHz is what a Bluetooth headset presents.
    private static let headset = (channels: AVAudioChannelCount(1), sampleRate: 24_000.0)

    /// 2 channels at 44.1 kHz is what the built-in microphone presents.
    private static let builtIn = (channels: AVAudioChannelCount(2), sampleRate: 44_100.0)

    private func buffer(
        channels: AVAudioChannelCount,
        sampleRate: Double,
        seconds: Double,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = amplitude * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func feed(
        _ recorder: AudioRecorder,
        channels: AVAudioChannelCount,
        sampleRate: Double,
        seconds: Double,
        amplitude: Float = 0.5
    ) {
        let target = AudioRecorder.makeTargetFormat()!
        recorder.appendConverted(
            buffer(channels: channels, sampleRate: sampleRate, seconds: seconds, amplitude: amplitude),
            to: target
        )
    }

    @Test("A 16 kHz mono target format is always constructible")
    func targetFormatIsConstructible() {
        let format = AudioRecorder.makeTargetFormat()
        #expect(format != nil)
        #expect(format?.sampleRate == AudioRecorder.targetSampleRate)
        #expect(format?.channelCount == 1)
    }

    @Test("Built-in microphone audio converts to the target rate")
    func convertsBuiltInMicrophoneFormat() {
        let recorder = AudioRecorder()
        feed(recorder, channels: Self.builtIn.channels, sampleRate: Self.builtIn.sampleRate, seconds: 0.5)

        #expect(recorder.recordedSeconds > 0.4)
        #expect(recorder.recordedSeconds < 0.6)
    }

    @Test("Bluetooth headset audio converts to the target rate")
    func convertsHeadsetFormat() {
        let recorder = AudioRecorder()
        feed(recorder, channels: Self.headset.channels, sampleRate: Self.headset.sampleRate, seconds: 0.5)

        #expect(recorder.recordedSeconds > 0.4)
        #expect(recorder.recordedSeconds < 0.6)
    }

    /// The regression test.
    ///
    /// Before the fix the converter was built once in `start()` from a format
    /// read off the input node, so a buffer arriving in any other format was
    /// either mangled or dropped. The tap now carries no assumed format and the
    /// converter is rebuilt from whatever actually arrives.
    @Test("Audio continues to convert when the input format changes mid-recording")
    func rebuildsConverterWhenInputFormatChanges() {
        let recorder = AudioRecorder()

        feed(recorder, channels: Self.headset.channels, sampleRate: Self.headset.sampleRate, seconds: 0.5)
        let afterHeadset = recorder.recordedSeconds
        #expect(afterHeadset > 0.4)

        // The headset disconnects and the built-in microphone takes over.
        feed(recorder, channels: Self.builtIn.channels, sampleRate: Self.builtIn.sampleRate, seconds: 0.5)
        let afterBuiltIn = recorder.recordedSeconds

        #expect(afterBuiltIn > afterHeadset + 0.4, "audio from the second device was dropped")
    }



    // MARK: - Losing the input device
    //
    // These feed at 48 kHz rather than 16 kHz because the durations have to be
    // accurate: converting 16 kHz to a 16 kHz target takes a pass-through path
    // in AVAudioConverter that stops at 4096 frames, so a single large buffer
    // arrives as 0.256 s whatever was put in. Real hardware presents 44.1 or
    // 48 kHz and converts faithfully, and the capture session delivers small
    // buffers, so the application never meets that cap.

    /// With the change no longer ending a recording, a device that has genuinely
    /// gone away has to be noticed some other way. Audio arriving is the thing
    /// that actually matters, so that is what is measured.
    @Test("Audio arriving resets the stall clock")
    func audioArrivingResetsTheStallClock() async throws {
        let recorder = AudioRecorder()

        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 0.2)
        let immediatelyAfter = recorder.secondsSinceAudio
        #expect(immediatelyAfter < 0.1, "a buffer that just arrived reads as stale")

        try await Task.sleep(for: .milliseconds(300))
        let later = recorder.secondsSinceAudio
        #expect(later > 0.2, "the clock did not advance while no audio arrived")

        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 0.2)
        #expect(recorder.secondsSinceAudio < later, "fresh audio did not reset the clock")
    }

    /// A recorder that has never been started is not stalled — it is idle. The
    /// caller only consults this while recording, and reporting a huge age
    /// before the first recording would make the very first one look dead.
    @Test("An idle recorder reports no stall")
    func idleRecorderReportsNoStall() {
        let recorder = AudioRecorder()

        #expect(recorder.secondsSinceAudio == 0)
    }

    // MARK: - Waking the device

    /// A Bluetooth headset leaving its music profile delivers buffers before it
    /// delivers sound, and those buffers are bit-exact zero. Counting them makes
    /// the timer start at two or three seconds and hands the transcriber a block
    /// of nothing, so they are dropped the moment real audio arrives.
    @Test("Silence from a device that has not woken yet is discarded")
    func warmUpSilenceIsDiscarded() {
        let recorder = AudioRecorder()

        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 2.0, amplitude: 0)
        #expect(recorder.hasHeardAudio == false, "bit-exact silence was mistaken for audio")
        #expect(recorder.recordedSeconds > 1.5, "the buffers were not accumulated at all")

        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 0.5, amplitude: 0.5)

        #expect(recorder.hasHeardAudio, "real audio was mistaken for silence")
        #expect(recorder.recordedSeconds > 0.4, "the audio that woke the device was dropped too")
        #expect(recorder.recordedSeconds < 0.7, "the warm-up silence was kept, so the timer starts late")
    }

    /// The negative control. A device that is awake from the first buffer must
    /// lose nothing, or every recording on a wired microphone would be trimmed.
    @Test("A device awake from the first buffer loses nothing")
    func awakeDeviceKeepsEverything() {
        let recorder = AudioRecorder()

        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 0.5, amplitude: 0.5)
        #expect(recorder.hasHeardAudio)

        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 0.5, amplitude: 0.5)

        #expect(recorder.recordedSeconds > 0.9, "audio was discarded after the device was awake")
    }

    @Test("Silence produces a level of zero and speech does not")
    func levelsTrackAmplitude() {
        let quiet = AudioRecorder()
        feed(quiet, channels: 1, sampleRate: 16_000, seconds: 0.2, amplitude: 0)
        #expect(quiet.currentLevel == 0)

        let loud = AudioRecorder()
        feed(loud, channels: 1, sampleRate: 16_000, seconds: 0.2, amplitude: 0.5)
        #expect(loud.currentLevel > 0.1)
    }

    @Test("The level history is capped so it cannot grow without bound")
    func levelHistoryIsCapped() {
        let recorder = AudioRecorder()
        for _ in 0..<(AudioRecorder.levelHistoryLength + 20) {
            feed(recorder, channels: 1, sampleRate: 16_000, seconds: 0.02)
        }
        #expect(recorder.recentLevels.count == AudioRecorder.levelHistoryLength)
    }



    @Test("Stopping returns the captured audio and clears the buffer")
    func stopClearsState() async {
        let recorder = AudioRecorder()
        feed(recorder, channels: 1, sampleRate: 16_000, seconds: 0.3)
        #expect(recorder.recordedSeconds > 0.2)

        // `stop()` is a no-op unless the engine is running, so the buffer is
        // checked directly rather than through the engine lifecycle.
        #expect(await recorder.stop().isEmpty)
    }

    // MARK: - Deadlines
    //
    // A CoreAudio call that never returns cannot be produced on demand, so these
    // occupy the audio queue directly instead. That reproduces the part that
    // caused the outage: the queue stops draining, and every operation behind it
    // waits for something that is not coming.

    /// Short enough to wait for, long enough that the machine being busy cannot
    /// trip it on its own.
    private static let testTimeout: TimeInterval = 0.2

    /// Before this, `start()` awaited a continuation that a hung queue could
    /// never resume. The caller stayed suspended for the life of the process,
    /// never cleared its "already starting" guard, and every later press of the
    /// shortcut was swallowed by that guard in silence.
    @Test("A start the audio queue never runs fails instead of waiting for ever")
    func startFailsWhenTheQueueIsWedged() async {
        let recorder = AudioRecorder(engineTimeout: Self.testTimeout)
        recorder.blockEngineQueueForTesting(seconds: 5)

        await #expect(throws: AudioRecorder.RecorderError.self) {
            try await recorder.start()
        }
    }

    /// Failing the one recording is not enough. A serial queue that is still
    /// blocked is one nothing else will ever run on either, so the queue itself
    /// has to be written off, or the first hang takes every later recording with
    /// it and only a restart brings the application back.
    @Test("A wedged queue is abandoned so later work does not queue up behind it")
    func aWedgedQueueIsReplaced() async {
        let recorder = AudioRecorder(engineTimeout: Self.testTimeout)
        let before = recorder.engineGenerationForTesting

        recorder.blockEngineQueueForTesting(seconds: 5)
        _ = try? await recorder.start()

        #expect(recorder.engineGenerationForTesting == before + 1, "the hung queue is still in use")

        // The abandoned queue has several seconds left to run. Getting through
        // the queue at all proves this is no longer that queue: the old one
        // would block until its sleep finished.
        let started = Date()
        recorder.setRunningForTesting(false)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1, "the replacement queue is still stuck behind the abandoned one")
    }

    /// The samples are held under the sample lock, not on the audio queue, so
    /// they remain reachable when the engine that produced them does not. A
    /// dictation that has already been spoken should still be transcribed even
    /// though the hardware has stopped answering.
    @Test("Audio already captured survives a stop the audio queue never runs")
    func stopSalvagesAudioFromAWedgedQueue() async {
        let recorder = AudioRecorder(engineTimeout: Self.testTimeout)
        feed(recorder, channels: 1, sampleRate: 16_000, seconds: 0.3)

        recorder.blockEngineQueueForTesting(seconds: 5)
        let captured = await recorder.stop()

        #expect(captured.isEmpty == false, "the recording was thrown away with the engine")
        #expect(recorder.recordedSeconds == 0, "the buffer was not cleared for the next recording")
    }

    /// Negative control for the three above: with the queue free, nothing times
    /// out and no queue is abandoned. Without this, a mistake that made every
    /// operation time out would leave the tests above passing.
    @Test("A queue that is not wedged is left alone")
    func aFreeQueueIsNeverAbandoned() async {
        let recorder = AudioRecorder(engineTimeout: Self.testTimeout)
        let before = recorder.engineGenerationForTesting

        _ = await recorder.stop()
        try? await Task.sleep(for: .milliseconds(400))

        #expect(recorder.engineGenerationForTesting == before, "a queue that answered in time was abandoned")
    }

    /// The engine an abandoned queue is holding is never stopped, because
    /// stopping it would take the lock that is already held. It therefore keeps
    /// delivering buffers, and without the generation check in the tap those
    /// would land in the buffer the next recording is filling.
    @Test("A tap belonging to an abandoned engine stops contributing audio")
    func abandonedTapsFallSilent() async {
        let recorder = AudioRecorder(engineTimeout: Self.testTimeout)
        let target = AudioRecorder.makeTargetFormat()!

        recorder.blockEngineQueueForTesting(seconds: 5)
        _ = try? await recorder.start()

        let abandoned = recorder.engineGenerationForTesting - 1
        recorder.handleTapBuffer(
            buffer(channels: 1, sampleRate: 16_000, seconds: 0.3),
            to: target,
            generation: abandoned
        )
        #expect(recorder.recordedSeconds == 0, "a dead engine is still feeding the next recording")

        // The live engine's tap is unaffected, so the check is discriminating
        // rather than simply refusing everything.
        recorder.handleTapBuffer(
            buffer(channels: 1, sampleRate: 16_000, seconds: 0.3),
            to: target,
            generation: abandoned + 1
        )
        #expect(recorder.recordedSeconds > 0.2, "the current engine's audio was dropped too")
    }

}
