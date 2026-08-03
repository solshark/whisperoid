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
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?

    /// Converter for the format the tap is currently delivering, together with
    /// the format it was built for. Rebuilt whenever a buffer arrives in a
    /// different format, which is the only reliable signal of what the hardware
    /// is actually producing.
    private var cachedConverter: AVAudioConverter?
    private var cachedConverterFormat: AVAudioFormat?

    /// Called when the audio hardware configuration changes while recording,
    /// which happens when a device is connected, removed, or made the default.
    ///
    /// Capture cannot meaningfully continue across the change, so the recording
    /// is finished early rather than left running against hardware that may no
    /// longer be delivering anything.
    public var onConfigurationChange: (@Sendable () -> Void)?

    /// The observer is installed for the object's whole life, not only while
    /// recording.
    ///
    /// A device change *between* recordings is the case that matters. The engine
    /// caches the input node's format, and once the device behind it is gone
    /// that cache describes hardware that no longer exists. Watching only during
    /// capture left every such change unobserved, and the next `start()` then
    /// worked from a stale format.
    public init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

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

    /// The format every recording is converted to before it reaches Whisper.
    static func makeTargetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    public func start() throws {
        guard !isRunning else { return }

        guard let targetFormat = Self.makeTargetFormat() else {
            throw RecorderError.engineFailed("could not build a 16 kHz mono format")
        }

        lock.lock()
        samples.removeAll()
        levels.removeAll()
        level = 0
        cachedConverter = nil
        cachedConverterFormat = nil
        lock.unlock()

        let input = engine.inputNode

        // A tap left behind by an earlier failure makes `installTap` raise, so
        // clear one before installing. Removing a tap that is not there does
        // nothing and is safe.
        input.removeTap(onBus: 0)

        // The format is deliberately nil, which means "whatever this bus is
        // actually producing".
        //
        // Passing a format read from the node instead bakes in a value the
        // engine has cached, and that cache goes stale the moment the input
        // device changes. `installTap` then raises an Objective-C exception,
        // which Swift cannot catch: it unwinds through Swift frames without
        // running any cleanup and leaves the concurrency runtime inconsistent.
        // The process survives, appears to do nothing, and then dies at the next
        // main-actor isolation check somewhere entirely unrelated.
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            self?.appendConverted(buffer, to: targetFormat)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
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

        lock.lock()
        let captured = samples
        samples.removeAll()
        levels.removeAll()
        level = 0
        cachedConverter = nil
        cachedConverterFormat = nil
        lock.unlock()

        return captured
    }

    /// Stops capture and discards everything recorded.
    public func cancel() {
        _ = stop()
    }

    /// Responds to a hardware configuration change.
    ///
    /// Whether recording or idle, the cached converter is dropped: it was built
    /// for a format that is no longer guaranteed to be what the hardware
    /// delivers. When idle the engine is also stopped, so the next `start()`
    /// attaches to the device that is actually present rather than to whatever
    /// was there when the engine last looked.
    func handleConfigurationChange() {
        lock.lock()
        cachedConverter = nil
        cachedConverterFormat = nil
        lock.unlock()

        if isRunning {
            onConfigurationChange?()
        } else {
            engine.stop()
        }
    }

    /// Returns a converter from `inputFormat`, building one if the format has
    /// changed since the last buffer.
    private func converter(
        from inputFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) -> AVAudioConverter? {
        lock.lock()
        if let existing = cachedConverter, cachedConverterFormat == inputFormat {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let made = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }

        lock.lock()
        cachedConverter = made
        cachedConverterFormat = inputFormat
        lock.unlock()

        return made
    }

    func appendConverted(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) {
        guard buffer.frameLength > 0 else { return }
        guard let converter = converter(from: buffer.format, to: targetFormat) else { return }

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
