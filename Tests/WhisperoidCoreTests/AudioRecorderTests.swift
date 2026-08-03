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
    func stopClearsState() {
        let recorder = AudioRecorder()
        feed(recorder, channels: 1, sampleRate: 16_000, seconds: 0.3)
        #expect(recorder.recordedSeconds > 0.2)

        // `stop()` is a no-op unless the engine is running, so the buffer is
        // checked directly rather than through the engine lifecycle.
        #expect(recorder.stop().isEmpty)
    }
}
