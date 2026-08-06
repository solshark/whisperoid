import AVFoundation
import Foundation

/// Captures microphone audio and converts it on the fly to the 16 kHz mono
/// Float32 format Whisper expects. Samples accumulate until `stop()` is called.
///
/// There are two kinds of state here and they are synchronised differently,
/// because they have different callers:
///
/// - The engine and its lifecycle are confined to `engineQueue`. Every call into
///   AVAudioEngine goes through it, which serialises our own access and keeps
///   CoreAudio off the main thread.
/// - The sample buffer and level history are guarded by `lock`, because the tap
///   callback runs on a realtime audio thread that must not block on a queue,
///   and the UI reads them at 20 Hz from the main actor.
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

    /// Serialises every call into AVAudioEngine, and keeps them off the main
    /// thread.
    ///
    /// `AVAudioEngine.inputNode` enumerates the audio hardware synchronously. On
    /// a machine with several devices attached that walk is slow, and if the
    /// hardware topology changes while it is in progress it can stop making
    /// progress at all: AVFAudio's own queue blocks on the engine's recursive
    /// mutex, which is held by whoever is inside `inputNode`.
    ///
    /// That contention belongs to CoreAudio and cannot be fixed from here. What
    /// can be fixed is which thread gets caught in it. On the main thread the
    /// whole application stops answering — no menu, no hotkey, nothing, until it
    /// is killed. On this queue a dictation fails and the user still has an app.
    private let engineQueue = DispatchQueue(label: "com.solshark.whisperoid.audio-engine")

    /// Replaced for every recording. See `renewEngine()`. Confined to
    /// `engineQueue`, as are `isRunning`, `configurationObserver` and
    /// `configurationChangeCount`.
    private var engine = AVAudioEngine()
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var configurationChangeCount = 0

    private let lock = NSLock()
    private var samples: [Float] = []
    private var level: Float = 0
    private var levels: [Float] = []

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
    ///
    /// Invoked on `engineQueue`, so an implementation that touches UI has to hop
    /// to the main actor itself.
    public var onConfigurationChange: (@Sendable () -> Void)?

    /// Counts handled configuration changes so tests can prove the observer is
    /// attached to the engine currently in use.
    var configurationChangesHandled: Int {
        engineQueue.sync { configurationChangeCount }
    }

    /// Identifies the engine in use, so tests can prove `renewEngine()` really
    /// replaced it rather than reconfiguring the old one.
    var engineIdentity: ObjectIdentifier {
        engineQueue.sync { ObjectIdentifier(engine) }
    }

    public init() {
        // Direct rather than through the queue: nothing else can reach this
        // object yet, and the first dispatch onto `engineQueue` orders this
        // write ahead of anything the queue goes on to do.
        observeConfigurationChangesOnQueue()
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Engine lifecycle
    //
    // Everything from here to the end of the section runs on `engineQueue`. The
    // `OnQueue` methods assume they are already there; the wrappers above them
    // are the way in from anywhere else.

    /// Attaches the configuration-change observer to the current engine.
    ///
    /// The notification is posted per engine instance, so this has to be redone
    /// every time the engine is replaced or the new one is watched by nobody.
    private func observeConfigurationChangesOnQueue() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        // `queue: nil` delivers on whichever thread posted, which for the real
        // notification is one of CoreAudio's. The handler is hopped onto
        // `engineQueue` explicitly instead. Asking for `.main` here would put
        // an engine call back on the main thread, which is the whole problem.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            engineQueue.async { self.handleConfigurationChangeOnQueue() }
        }
    }

    /// Posts the configuration-change notification for the engine currently in
    /// use, so a test can verify the observer is attached to it. The real
    /// notification comes from AVAudioEngine and cannot be provoked on demand.
    func postConfigurationChangeForTesting() {
        engineQueue.sync {
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: engine
            )
        }
    }

    /// Discards the engine and builds a fresh one.
    ///
    /// AVAudioEngine reads the input hardware's format when it is created and
    /// caches it. It announces later changes through
    /// `AVAudioEngineConfigurationChange`, but only while it is *running*, so an
    /// engine sitting idle between recordings is told nothing: a headset
    /// connecting, a device disappearing, or a sleep and wake cycle all pass
    /// unnoticed. The cached format then describes hardware that is no longer
    /// there, and the next recording fails with -10868, formats don't match.
    ///
    /// Observing harder does not fix this because there is no notification to
    /// observe. A new engine queries the hardware as it stands, which is the
    /// only reliable answer, and building one costs microseconds.
    func renewEngine() {
        engineQueue.sync { renewEngineOnQueue() }
    }

    private func renewEngineOnQueue() {
        engine.stop()
        engine = AVAudioEngine()
        observeConfigurationChangesOnQueue()
    }

    /// Responds to a hardware configuration change.
    ///
    /// Whether recording or idle, the cached converter is dropped: it was built
    /// for a format that is no longer guaranteed to be what the hardware
    /// delivers. When idle the engine is also stopped, so the next `start()`
    /// attaches to the device that is actually present rather than to whatever
    /// was there when the engine last looked.
    func handleConfigurationChange() {
        engineQueue.sync { handleConfigurationChangeOnQueue() }
    }

    private func handleConfigurationChangeOnQueue() {
        configurationChangeCount += 1

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

    // MARK: - Capture

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

    /// Begins capture. Suspends until the engine is running, which can take a
    /// while: see `engineQueue`.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async {
                do {
                    try self.startOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnQueue() throws {
        guard !isRunning else { return }

        // Built here rather than passed in, so no AVFoundation object has to
        // cross onto this queue from the caller.
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

        // Before anything else, so the format below is read from the hardware
        // that is present now rather than whatever was there last time.
        renewEngineOnQueue()

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
    public func stop() async -> [Float] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float], Never>) in
            engineQueue.async {
                continuation.resume(returning: self.stopOnQueue())
            }
        }
    }

    private func stopOnQueue() -> [Float] {
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
    public func cancel() async {
        _ = await stop()
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
