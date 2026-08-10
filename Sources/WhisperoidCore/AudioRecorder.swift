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
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .engineFailed(let detail):
                "Audio engine failed: \(detail)"
            case .timedOut(let operation):
                """
                The audio system stopped responding while trying to \(operation). \
                This is usually macOS's coreaudiod, not Whisperoid. Try again, \
                and if it keeps happening, disconnect and reconnect the input \
                device or restart the Mac.
                """
            }
        }
    }

    /// Whisper operates on 16 kHz mono audio.
    public static let targetSampleRate: Double = 16_000

    /// How many recent level readings to retain for the waveform display.
    public static let levelHistoryLength = 48

    /// How long an engine operation may take before it is abandoned.
    ///
    /// Generous on purpose. Enumerating the audio hardware genuinely takes a
    /// few hundred milliseconds with several devices attached, and a deadline
    /// tight enough to catch a slow machine would fail recordings that were
    /// only ever going to be late. The failure this guards against is not slow,
    /// it is infinite: the observed hang sat in one CoreAudio call for over
    /// forty minutes.
    public static let defaultEngineTimeout: TimeInterval = 5

    /// Per-instance so tests can pick a deadline they can wait for. Nothing in
    /// the application passes one.
    public let engineTimeout: TimeInterval

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
    ///
    /// Moving off the main thread was not by itself enough. A serial queue whose
    /// front block never returns is a queue nothing else will ever run on, so
    /// the first hang took every later recording with it: `start()` awaited a
    /// continuation that could not be resumed, its caller never cleared the
    /// guard that stops two recordings starting at once, and the shortcut went
    /// quiet for the rest of the process's life. Hence `engineGeneration` and
    /// the replacement in `abandonQueue(generation:operation:)` — a wedged queue
    /// is written off rather than waited on.
    private var engineQueue = AudioRecorder.makeEngineQueue()

    private static func makeEngineQueue() -> DispatchQueue {
        DispatchQueue(label: "com.solshark.whisperoid.audio-engine")
    }

    /// Incremented whenever a queue is abandoned, which makes every reference to
    /// the engine that the abandoned queue still holds detectably stale.
    ///
    /// A hung CoreAudio call is not guaranteed to hang forever. If it returns
    /// after its queue has been written off, the block it belongs to resumes and
    /// starts operating on state a newer queue now owns. The generation it
    /// captured no longer matches, which is how it finds out to stop.
    private var engineGeneration = 0

    /// Guards `engineQueue` and `engineGeneration` only. Deliberately not `lock`:
    /// this one is taken from the watchdog while the audio queue is unreachable,
    /// and must never be held across a call into AVFoundation.
    private let queueLock = NSLock()

    /// Runs the deadline timers. Never touches the engine, so it stays
    /// responsive precisely when the audio queue does not.
    private let watchdogQueue = DispatchQueue(label: "com.solshark.whisperoid.audio-engine-watchdog")

    /// Replaced for every recording. See `renewEngine()`. Confined to
    /// `engineQueue`, as are `isRunning`, `configurationObserver` and
    /// `configurationChangeCount`.
    private var engine = AVAudioEngine()
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var configurationChangeCount = 0

    private let lock = NSLock()
    private var configurationChangeEndedRecording = false
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
    /// Capture cannot meaningfully continue across the change — the tap does not
    /// survive it — so the recording is finished with whatever it has rather
    /// than left running against hardware that is no longer delivering.
    ///
    /// Invoked on `engineQueue`, so an implementation that touches UI has to hop
    /// to the main actor itself.
    public var onConfigurationChange: (@Sendable () -> Void)?

    /// Whether the recording that just ended was cut short by the input
    /// hardware reconfiguring rather than by the user. Read after `stop()`.
    ///
    /// The distinction matters because the two produce identical symptoms. A
    /// device that never delivers a microphone stream yields a recording of
    /// almost nothing, which is indistinguishable from someone tapping the
    /// shortcut twice by accident — and reporting the second when it was the
    /// first sends the user looking in entirely the wrong place.
    public var endedByConfigurationChange: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configurationChangeEndedRecording
    }

    /// Called with the name of the operation that exceeded `engineTimeout`.
    ///
    /// The user already learns about this from the error the operation throws.
    /// This exists so it also reaches the log, because a hang that leaves no
    /// trace is one that has to be diagnosed with a debugger attached to a live
    /// process, and by then the evidence is usually gone.
    ///
    /// Invoked on the watchdog queue.
    public var onEngineTimeout: (@Sendable (String) -> Void)?

    /// Counts handled configuration changes so tests can prove the observer is
    /// attached to the engine currently in use.
    var configurationChangesHandled: Int {
        currentQueue.sync { configurationChangeCount }
    }

    /// Identifies the engine in use, so tests can prove `renewEngine()` really
    /// replaced it rather than reconfiguring the old one.
    var engineIdentity: ObjectIdentifier {
        currentQueue.sync { ObjectIdentifier(engine) }
    }

    /// Forces the running flag. Starting for real needs hardware, so this is the
    /// only way to reach the branches that apply only mid-recording.
    func setRunningForTesting(_ running: Bool) {
        currentQueue.sync { isRunning = running }
    }

    /// How many times a queue has been abandoned, so tests can prove a deadline
    /// was enforced rather than merely survived.
    var engineGenerationForTesting: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return engineGeneration
    }

    /// Occupies the audio queue for `seconds`, standing in for the CoreAudio
    /// call that does not return.
    ///
    /// A real hang needs coreaudiod to stop answering, which cannot be arranged
    /// from a test. What can be arranged is the thing that actually matters: a
    /// serial queue whose front block is not finishing, and everything that was
    /// scheduled behind it.
    func blockEngineQueueForTesting(seconds: TimeInterval) {
        currentQueue.async { Thread.sleep(forTimeInterval: seconds) }
    }

    public init(engineTimeout: TimeInterval = AudioRecorder.defaultEngineTimeout) {
        self.engineTimeout = engineTimeout

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

    // MARK: - Deadlines

    /// Resumes a continuation at most once, whoever gets there first.
    ///
    /// Both the queue and the watchdog race to finish the same operation, and
    /// resuming a `CheckedContinuation` twice traps. `resume` reports whether it
    /// was the one that won, which is what tells the watchdog it is looking at a
    /// real timeout rather than a normal completion it merely arrived after.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        private func take() -> CheckedContinuation<T, Error>? {
            lock.lock()
            defer { lock.unlock() }

            let taken = continuation
            continuation = nil
            return taken
        }

        @discardableResult
        func resume(returning value: T) -> Bool {
            guard let continuation = take() else { return false }
            continuation.resume(returning: value)
            return true
        }

        @discardableResult
        func resume(throwing error: Error) -> Bool {
            guard let continuation = take() else { return false }
            continuation.resume(throwing: error)
            return true
        }
    }

    private var currentQueue: DispatchQueue {
        currentQueueAndGeneration().queue
    }

    /// Both together, under one acquisition, so a caller cannot end up
    /// scheduling onto one queue while labelling the work with another's
    /// generation.
    ///
    /// Not a computed property pair: `withEngineQueue` is async, and Swift
    /// forbids taking an `NSLock` directly in an async body. Reading them
    /// through a synchronous call is how that rule is satisfied without
    /// widening the lock's scope.
    private func currentQueueAndGeneration() -> (queue: DispatchQueue, generation: Int) {
        queueLock.lock()
        defer { queueLock.unlock() }
        return (engineQueue, engineGeneration)
    }

    /// Whether `generation` still describes the queue that owns the engine.
    private func isCurrent(_ generation: Int) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return generation == engineGeneration
    }

    /// Runs `work` on the audio queue, giving up after `engineTimeout`.
    ///
    /// The generation handed to `work` is the one current when it was scheduled,
    /// so a block that outlives its deadline can tell that it has.
    private func withEngineQueue<T: Sendable>(
        _ operation: String,
        _ work: @escaping @Sendable (Int) throws -> T
    ) async throws -> T {
        let (queue, generation) = currentQueueAndGeneration()

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)

            queue.async {
                do {
                    once.resume(returning: try work(generation))
                } catch {
                    once.resume(throwing: error)
                }
            }

            watchdogQueue.asyncAfter(deadline: .now() + engineTimeout) { [weak self] in
                guard once.resume(throwing: RecorderError.timedOut(operation)) else { return }
                self?.abandonQueue(generation: generation, operation: operation)
            }
        }
    }

    /// Writes off a queue whose front block has not returned, and starts again
    /// on a fresh one.
    ///
    /// The hung block is not cancelled, because it cannot be: it is parked in
    /// the kernel waiting on a reply from coreaudiod that may never come. Its
    /// thread is simply surrendered for the life of the process. That is a leak,
    /// and an acceptable one — it costs no CPU, and `engineTimeout` bounds how
    /// fast they can accumulate to one per five seconds of a user still trying.
    ///
    /// The replacement engine is built rather than the old one reused, and the
    /// old one is *not* stopped on the way out: `stop()` takes the same lock the
    /// hung call is holding, so tidying up would wedge the fresh queue exactly
    /// as the old one is wedged. It is left to the abandoned block, which owns
    /// the only other reference to it and will release it if it ever returns.
    private func abandonQueue(generation: Int, operation: String) {
        queueLock.lock()
        guard generation == engineGeneration else {
            queueLock.unlock()
            return
        }
        engineGeneration += 1
        engineQueue = Self.makeEngineQueue()
        let fresh = engineQueue
        queueLock.unlock()

        onEngineTimeout?(operation)

        fresh.async {
            // Cleared before the engine is replaced: a hung `stop()` never got
            // to do it, and leaving it set would make the next `start()` decide
            // it was already recording and return to a caller that then waits
            // for audio from an engine that no longer exists.
            self.isRunning = false
            self.engine = AVAudioEngine()
            self.observeConfigurationChangesOnQueue()
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

            // Tagged with the generation it was scheduled under for the same
            // reason `start()` and `stop()` are: if this queue is written off
            // before the block runs, the block must not go on to touch state a
            // newer queue has taken over.
            let (queue, generation) = currentQueueAndGeneration()
            queue.async {
                guard self.isCurrent(generation) else { return }
                self.handleConfigurationChangeOnQueue()
            }
        }
    }

    /// Posts the configuration-change notification for the engine currently in
    /// use, so a test can verify the observer is attached to it. The real
    /// notification comes from AVAudioEngine and cannot be provoked on demand.
    func postConfigurationChangeForTesting() {
        currentQueue.sync {
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
        currentQueue.sync { renewEngineOnQueue() }
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
        currentQueue.sync { handleConfigurationChangeOnQueue() }
    }

    private func handleConfigurationChangeOnQueue() {
        configurationChangeCount += 1

        lock.lock()
        cachedConverter = nil
        cachedConverterFormat = nil
        lock.unlock()

        guard isRunning else {
            engine.stop()
            return
        }

        // Noted before the callback, so whoever finishes the recording can tell
        // the user why it ended. Rebuilding capture here was tried and removed:
        // a tap does not survive the change, but restarting the engine is what
        // provokes the next change on a device that cannot supply a microphone,
        // so it rebuilt five times, captured 0.17 s, and failed anyway.
        lock.lock()
        configurationChangeEndedRecording = true
        lock.unlock()

        onConfigurationChange?()
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
        try await withEngineQueue("start recording") { generation in
            try self.startOnQueue(generation: generation)
        }
    }

    private func startOnQueue(generation: Int) throws {
        guard !isRunning else { return }

        _ = drainSamples()

        lock.lock()
        configurationChangeEndedRecording = false
        lock.unlock()

        try beginCaptureOnQueue(generation: generation)

        guard isCurrent(generation) else {
            throw RecorderError.timedOut("start recording")
        }

        isRunning = true
    }

    /// Builds an engine, installs the tap and starts capture, leaving whatever
    /// has already been recorded alone.
    ///
    /// Kept separate from the bookkeeping in `startOnQueue` because this is the
    /// part that touches hardware and the part that can therefore hang.
    private func beginCaptureOnQueue(generation: Int) throws {
        // Built here rather than passed in, so no AVFoundation object has to
        // cross onto this queue from the caller.
        guard let targetFormat = Self.makeTargetFormat() else {
            throw RecorderError.engineFailed("could not build a 16 kHz mono format")
        }

        // Before anything else, so the format below is read from the hardware
        // that is present now rather than whatever was there last time.
        renewEngineOnQueue()

        // Held locally for the rest of the method. If this attempt is abandoned
        // partway through, `self.engine` becomes a different object, and the
        // teardown below has to act on the one it actually built.
        let engine = self.engine

        // The call that hangs. Everything above is arithmetic; this asks
        // CoreAudio to enumerate the hardware, and on a bad day it never
        // answers.
        let input = engine.inputNode

        // Whoever was waiting has already been handed a timeout and a new queue
        // owns the engine now. Carrying on would install a tap that feeds a
        // buffer belonging to a recording this one knows nothing about.
        guard isCurrent(generation) else {
            throw RecorderError.timedOut("start recording")
        }

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
            self?.handleTapBuffer(buffer, to: targetFormat, generation: generation)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }

    /// Stops capture and returns everything recorded, clearing the buffer.
    ///
    /// Cannot fail. Tearing the engine down can hang exactly as starting it can,
    /// but the samples do not live on the audio queue — they are under `lock`,
    /// where the tap put them — so a recording is still recoverable when the
    /// hardware that produced it has stopped answering. The engine is written
    /// off and the audio is handed back regardless.
    @discardableResult
    public func stop() async -> [Float] {
        do {
            return try await withEngineQueue("stop recording") { generation in
                self.stopOnQueue(generation: generation)
            }
        } catch {
            return drainSamples()
        }
    }

    private func stopOnQueue(generation: Int) -> [Float] {
        guard isRunning else { return [] }

        // Cleared first. If the two calls below hang, this recording is over as
        // far as the rest of the object is concerned, and the next `start()`
        // must not mistake a dead engine for a live one.
        isRunning = false

        let engine = self.engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // The caller has already been given the samples by the timeout path.
        // Draining again here would hand back an empty array and lose nothing,
        // but only because the buffer is already empty — return early and leave
        // whatever the next recording has started collecting alone.
        guard isCurrent(generation) else { return [] }

        return drainSamples()
    }

    /// Takes everything captured so far and resets the buffer for the next
    /// recording. Safe from any thread; touches no AVFoundation object.
    @discardableResult
    private func drainSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let captured = samples
        samples.removeAll()
        levels.removeAll()
        level = 0
        cachedConverter = nil
        cachedConverterFormat = nil
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

    /// Receives one buffer from the tap.
    ///
    /// The generation check is what makes a tap fall silent once its engine has
    /// been abandoned. An abandoned engine is never stopped — nothing is able to
    /// stop it — so it goes on delivering buffers, and without this they would
    /// land in the buffer the next recording is filling and mix the two
    /// together.
    ///
    /// Named rather than written inline at the call site so that a test can
    /// drive it: the tap itself only exists once real hardware is attached.
    func handleTapBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat, generation: Int) {
        guard isCurrent(generation) else { return }
        appendConverted(buffer, to: targetFormat)
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
