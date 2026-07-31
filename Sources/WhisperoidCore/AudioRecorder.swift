import AVFoundation
import Foundation

/// Captures microphone audio and converts it on the fly to the 16 kHz mono
/// Float32 format Whisper expects. Samples accumulate until `stop()` is called.
///
/// The tap callback runs on a realtime audio thread, so shared state is guarded
/// by a lock rather than actor isolation.
public final class AudioRecorder: @unchecked Sendable {

    public enum RecorderError: LocalizedError {
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .engineFailed(let detail):
                "Audio engine failed: \(detail)"
            }
        }
    }

    /// Whisper operates on 16 kHz mono audio.
    public static let targetSampleRate: Double = 16_000

    /// How many recent level readings to retain for the waveform display.
    public static let levelHistoryLength = 48

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var level: Float = 0
    private var levels: [Float] = []
    private var converter: AVAudioConverter?
    private var isRunning = false

    public init() {}

    /// Most recent input level as RMS in 0...1, updated on every tap callback.
    public var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// Rolling window of recent RMS readings, oldest first, for waveform display.
    public var recentLevels: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    public var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }

    public func start() throws {
        guard !isRunning else { return }

        lock.lock()
        samples.removeAll()
        levels.removeAll()
        level = 0
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.engineFailed("input device reported a zero sample rate")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.engineFailed("could not build a 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.engineFailed("could not build a converter from \(inputFormat)")
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.appendConverted(buffer, to: targetFormat)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        isRunning = true
    }

    /// Stops capture and returns everything recorded, clearing the buffer.
    @discardableResult
    public func stop() -> [Float] {
        guard isRunning else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil

        lock.lock()
        let captured = samples
        samples.removeAll()
        levels.removeAll()
        level = 0
        lock.unlock()

        return captured
    }

    /// Stops capture and discards everything recorded.
    public func cancel() {
        _ = stop()
    }

    private func appendConverted(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The converter pulls input through this block; supply the buffer once,
        // then report that no more data is available for this conversion pass.
        //
        // The block is marked @Sendable but AVAudioConverter invokes it
        // synchronously on this thread before `convert` returns, so neither the
        // buffer nor the flag ever crosses a thread boundary.
        nonisolated(unsafe) let inputBuffer = buffer
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData
        else { return }

        let frameCount = Int(output.frameLength)
        let converted = Array(UnsafeBufferPointer(start: channel[0], count: frameCount))

        var sumOfSquares: Float = 0
        for sample in converted {
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frameCount)).squareRoot()

        lock.lock()
        samples.append(contentsOf: converted)
        level = rms
        levels.append(rms)
        if levels.count > Self.levelHistoryLength {
            levels.removeFirst(levels.count - Self.levelHistoryLength)
        }
        lock.unlock()
    }
}
