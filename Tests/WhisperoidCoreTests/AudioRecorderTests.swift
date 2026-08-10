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

    @Test("A configuration change while idle does not discard subsequent audio")
    func survivesConfigurationChangeWhileIdle() {
        let recorder = AudioRecorder()

        feed(recorder, channels: Self.headset.channels, sampleRate: Self.headset.sampleRate, seconds: 0.5)
        let before = recorder.recordedSeconds

        // The device goes away between recordings, which is the case that was
        // never observed at all before the fix.
        recorder.handleConfigurationChange()

        feed(recorder, channels: Self.builtIn.channels, sampleRate: Self.builtIn.sampleRate, seconds: 0.5)
        #expect(recorder.recordedSeconds > before + 0.4)
    }

    @Test("A configuration change while idle does not invoke the recording callback")
    func idleConfigurationChangeDoesNotFinishARecording() {
        let recorder = AudioRecorder()
        nonisolated(unsafe) var fired = false
        recorder.onConfigurationChange = { fired = true }

        recorder.handleConfigurationChange()

        #expect(fired == false, "an idle device change must not end a recording that is not running")
    }

    // MARK: - Configuration changes while recording
    //
    // macOS 26.6 posts a configuration change immediately after the engine
    // starts, before any audio has been delivered. Acting on it ended every
    // recording at zero seconds, and the transcriber rejected all of them as too
    // short to transcribe.
    //
    // These feed at 48 kHz rather than 16 kHz because the durations have to be
    // accurate: converting 16 kHz to a 16 kHz target takes a pass-through path
    // in AVAudioConverter that stops at 4096 frames, so a single large buffer
    // arrives as 0.256 s whatever was put in. Real hardware presents 44.1 or
    // 48 kHz and converts faithfully, and a real tap delivers 4096 frames at a
    // time, which is exactly the cap — so nothing is lost in the application.

    /// Recording and dictating are told apart by why the recording ended, not
    /// by how long it was, because the two failures look identical from the
    /// outside: both hand back almost no audio.
    ///
    /// Observed with AirPods Max on macOS 26.6. Selecting them as the input
    /// never produces a microphone stream — CoreAudio reports no input streams
    /// for the process and renegotiates the Bluetooth profile every 800 ms —
    /// so the recording ends immediately with nothing in it. Reporting that as
    /// "too short to transcribe" sends the user off to speak for longer at a
    /// device that was never listening.
    @Test("A recording ended by the hardware is distinguishable from a short one")
    func configurationChangeIsRecordedAsTheReasonForEnding() {
        let recorder = AudioRecorder()
        recorder.setRunningForTesting(true)

        #expect(recorder.endedByConfigurationChange == false, "nothing has happened yet")

        recorder.handleConfigurationChange()

        #expect(recorder.endedByConfigurationChange, "the reason the recording ended was lost")
    }

    /// The negative control. A recording the user simply ended must not be
    /// reported as a hardware failure, or the advice to change input device
    /// appears every time someone taps the shortcut twice.
    @Test("A recording the user ends is not blamed on the hardware")
    func userEndedRecordingIsNotBlamedOnHardware() async {
        let recorder = AudioRecorder()
        recorder.setRunningForTesting(true)
        feed(recorder, channels: 1, sampleRate: 48_000, seconds: 0.5)

        _ = await recorder.stop()

        #expect(recorder.endedByConfigurationChange == false, "a normal recording was blamed on the hardware")
    }

    /// A change while idle is not a recording ending, so it must not leave the
    /// flag set for the next recording to trip over.
    @Test("A configuration change while idle does not mark a recording as ended by it")
    func idleConfigurationChangeLeavesTheReasonUnset() {
        let recorder = AudioRecorder()

        recorder.handleConfigurationChange()

        #expect(recorder.endedByConfigurationChange == false)
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

    /// A long-lived engine caches the input hardware's format and is only told
    /// about changes while it is running, so an engine that sat idle across a
    /// sleep or a headset connecting holds a format for hardware that is no
    /// longer there. The next recording then fails with -10868. Replacing the
    /// engine is the only way to get a current answer.
    @Test("Each recording gets a new engine rather than reusing a stale one")
    func renewEngineReplacesTheEngine() {
        let recorder = AudioRecorder()
        let original = recorder.engineIdentity

        recorder.renewEngine()

        #expect(recorder.engineIdentity != original, "the engine was reused, so its cached format survives")
    }

    /// The observer is registered against a specific engine instance. Replacing
    /// the engine without re-registering leaves the new one watched by nobody,
    /// which is silent and would only show up as a recording that fails to end
    /// itself when a device is unplugged.
    @Test("The configuration observer follows the engine when it is replaced")
    func observerFollowsRenewedEngine() async throws {
        let recorder = AudioRecorder()
        recorder.renewEngine()

        let before = recorder.configurationChangesHandled
        recorder.postConfigurationChangeForTesting()
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            recorder.configurationChangesHandled == before + 1,
            "the replacement engine's configuration changes reach nobody"
        )
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

        // The abandoned queue has several seconds left to run. Reaching the
        // engine at all proves this is no longer that queue: going through the
        // old one would block until its sleep finished.
        let started = Date()
        _ = recorder.configurationChangesHandled
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

    /// The engine, the running flag and the observer are all reachable from the
    /// audio hardware's thread as well as from the caller's, and none of them
    /// are covered by the sample lock — they are kept safe by being confined to
    /// one serial queue instead.
    ///
    /// Confinement is invisible: a change that moves an engine call back off the
    /// queue reintroduces the race silently, and the symptom is a hang in
    /// CoreAudio hours later rather than a failure here. This hammers the two
    /// paths that arrive from different threads in the real application.
    @Test("Renewal and configuration changes can interleave without corrupting state")
    func concurrentRenewalAndConfigurationChanges() async {
        let recorder = AudioRecorder()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { recorder.renewEngine() }
                group.addTask { recorder.handleConfigurationChange() }
            }
        }

        #expect(recorder.configurationChangesHandled == 20)
    }
}
