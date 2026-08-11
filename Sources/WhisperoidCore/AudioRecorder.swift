import AVFoundation
import Foundation

/// Captures microphone audio and converts it on the fly to the 16 kHz mono
/// Float32 format Whisper expects. Samples accumulate until `stop()` is called.
///
/// There are two kinds of state here and they are synchronised differently,
/// because they have different callers:
///
/// - The capture session and its lifecycle are confined to `engineQueue`. Every
///   call that opens or closes a device goes through it, which serialises our
///   own access and keeps CoreAudio off the main thread.
/// - The sample buffer and level history are guarded by `lock`, because samples
///   are delivered on the capture session's own queue while the UI reads them
///   at 20 Hz from the main actor.
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

    /// Serialises opening and closing the input device, and keeps it off the
    /// main thread.
    ///
    /// Asking CoreAudio for hardware is synchronous and can be slow — on a
    /// machine with several devices attached, or one whose topology is changing
    /// underneath the call, it has been observed not to return at all.
    ///
    /// That belongs to CoreAudio and cannot be fixed from here. What can be
    /// fixed is which thread gets caught in it. On the main thread the whole
    /// application stops answering — no menu, no hotkey, nothing, until it is
    /// killed. On this queue a dictation fails and the user still has an app.
    ///
    /// Moving off the main thread was not by itself enough. A serial queue whose
    /// front block never returns is a queue nothing else will ever run on, so
    /// the first hang took every later recording with it: `start()` awaited a
    /// continuation that could not be resumed, its caller never cleared the
    /// guard that stops two recordings starting at once, and the shortcut went
    /// quiet for the rest of the process's life. Hence `engineGeneration` and
    /// the replacement in `abandonQueue(generation:operation:)` — a wedged queue
    /// is written off rather than waited on. `AVCaptureSession.startRunning()`
    /// is the blocking call this now guards.
    private var engineQueue = AudioRecorder.makeEngineQueue()

    private static func makeEngineQueue() -> DispatchQueue {
        DispatchQueue(label: "com.solshark.whisperoid.audio-engine")
    }

    /// Incremented whenever a queue is abandoned, which makes every reference to
    /// the session that the abandoned queue still holds detectably stale.
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

    /// Rebuilt for every recording, so each one resolves the input device as it
    /// stands rather than as it was. Confined to `engineQueue`, as is
    /// `isRunning`.
    ///
    /// `AVCaptureSession` rather than `AVAudioEngine` deliberately. The engine
    /// does not open the input device: it opens `CADefaultDeviceAggregate-<pid>`,
    /// a wrapper CoreAudio builds once per process to follow the default input.
    /// Built while the default cannot supply a microphone — a Bluetooth headset
    /// in its music profile cannot — that wrapper comes up with no input streams
    /// and stays broken for the life of the process. Rebuilding the engine does
    /// not help, because the replacement binds to the same wrapper: four rebuilds
    /// in sixteen seconds all reported the correct 24 kHz headset format and not
    /// one delivered a buffer. Only relaunching the application cleared it.
    ///
    /// A capture session has no such wrapper. It reads the same device the
    /// engine could not, in the same state, at the same moment.
    private var session: AVCaptureSession?
    private var isRunning = false

    /// Receives sample buffers off the capture session. Held because the output
    /// keeps only a weak reference to it.
    private var sampleReceiver: SampleReceiver?

    /// Delivers capture callbacks. Separate from `engineQueue` so a sample
    /// arriving never waits behind a device operation.
    private let sampleQueue = DispatchQueue(label: "com.solshark.whisperoid.audio-samples")

    private let lock = NSLock()

    /// Uptime, not wall clock: this measures a few seconds of elapsed time and
    /// must not be disturbed by the system clock being adjusted underneath it.
    private var lastAudioUptime: UInt64?
    private var reportedFirstBuffer = false
    private var heardAudio = false
    private var reportedDrop = false
    private var samples: [Float] = []
    private var level: Float = 0
    private var levels: [Float] = []

    /// Converter for the format the tap is currently delivering, together with
    /// the format it was built for. Rebuilt whenever a buffer arrives in a
    /// different format, which is the only reliable signal of what the hardware
    /// is actually producing.
    private var cachedConverter: AVAudioConverter?
    private var cachedConverterFormat: AVAudioFormat?

    /// Whether the device has delivered anything other than silence yet.
    ///
    /// A Bluetooth headset leaving its music profile delivers buffers before it
    /// delivers sound: correctly sized, correctly timed, and bit-exact zero. A
    /// recording started in that window looks live and hears nothing, so the
    /// user talks into it and loses the opening seconds. This is what separates
    /// the two, and it is exact — a working microphone in a silent room still
    /// produces non-zero samples, while a warming one produces none at all.
    public var hasHeardAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heardAudio
    }

    /// How long since the tap last delivered audio, measured from the start of
    /// the recording until the first buffer arrives.
    ///
    /// This is what distinguishes a device that has stopped from a device that
    /// has not started yet. A Bluetooth headset needs a moment to switch out of
    /// its music profile before it can supply a microphone at all — measured at
    /// 0.377 s for AirPods Max on macOS 26.6 — and during that window a
    /// recording looks identical to one whose device has been unplugged.
    public var secondsSinceAudio: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let lastAudioUptime else { return 0 }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastAudioUptime
        return Double(elapsed) / 1_000_000_000
    }

    /// Called with one-line notes about the capture path: which device the
    /// engine actually opened, what format it presents, when the first buffer
    /// arrived, and every point at which audio is dropped.
    ///
    /// Those drop points were previously silent returns, which is why a
    /// recording that captured nothing looked identical to one that captured
    /// nothing for a completely different reason.
    ///
    /// Called from the audio thread as well as the audio queue, so an
    /// implementation must be cheap and thread-safe. Emitted at most once per
    /// recording for each kind of event.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// Called with the name of the operation that exceeded `engineTimeout`.
    ///
    /// The user already learns about this from the error the operation throws.
    /// This exists so it also reaches the log, because a hang that leaves no
    /// trace is one that has to be diagnosed with a debugger attached to a live
    /// process, and by then the evidence is usually gone.
    ///
    /// Invoked on the watchdog queue.
    public var onEngineTimeout: (@Sendable (String) -> Void)?

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

    }

    deinit {
        session?.stopRunning()
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
            // for audio from a session that no longer exists.
            self.isRunning = false
            self.tearDownSessionOnQueue()
        }
    }

    // MARK: - Engine lifecycle
    //
    // Everything from here to the end of the section runs on `engineQueue`. The
    // `OnQueue` methods assume they are already there; the wrappers above them
    // are the way in from anywhere else.

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

        try beginCaptureOnQueue(generation: generation)

        guard isCurrent(generation) else {
            throw RecorderError.timedOut("start recording")
        }

        // Started here rather than on entry, so a slow engine build is not
        // counted against the device as a stall.
        lock.lock()
        lastAudioUptime = DispatchTime.now().uptimeNanoseconds
        reportedFirstBuffer = false
        reportedDrop = false
        heardAudio = false
        lock.unlock()

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

        tearDownSessionOnQueue()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.engineFailed("no audio input device is available")
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        guard session.canAddInput(deviceInput) else {
            session.commitConfiguration()
            throw RecorderError.engineFailed("the input device could not be added to the session")
        }
        session.addInput(deviceInput)

        let output = AVCaptureAudioDataOutput()

        // Float32 asked for explicitly rather than taking the device's word for
        // it. The converter can handle whatever arrives, but a predictable
        // format keeps the common path free of surprises.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let receiver = SampleReceiver { [weak self] buffer in
            self?.handleTapBuffer(buffer, to: targetFormat, generation: generation)
        }
        output.setSampleBufferDelegate(receiver, queue: sampleQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.engineFailed("the audio output could not be added to the session")
        }
        session.addOutput(output)
        session.commitConfiguration()

        // Whoever was waiting has already been handed a timeout and a new queue
        // owns capture now. Starting would deliver audio into a recording this
        // attempt knows nothing about.
        guard isCurrent(generation) else {
            throw RecorderError.timedOut("start recording")
        }

        self.session = session
        self.sampleReceiver = receiver

        onDiagnostic?("capture: device=\(device.localizedName) [\(device.uniqueID)]")

        // Blocking, and on a bad day slow: this is where CoreAudio is asked for
        // the hardware. It runs under the queue's deadline for that reason.
        session.startRunning()

        guard session.isRunning else {
            tearDownSessionOnQueue()
            throw RecorderError.engineFailed("the capture session would not start")
        }

        onDiagnostic?("capture: session running")
    }

    /// Stops and forgets the session, if there is one.
    private func tearDownSessionOnQueue() {
        guard let session else { return }
        if session.isRunning { session.stopRunning() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        self.session = nil
        sampleReceiver = nil
    }

    /// Receives sample buffers from the capture session and hands them on as
    /// `AVAudioPCMBuffer`, which is what the conversion path already speaks.
    ///
    /// The output holds this only weakly, so the recorder keeps it alive.
    private final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

        init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
            self.onBuffer = onBuffer
        }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: streamDescription)
            else { return }

            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else { return }
            buffer.frameLength = frames

            // Copied, not repointed.
            //
            // `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` fills a
            // buffer list by pointing its `mData` at the block buffer's memory.
            // Handed `AVAudioPCMBuffer`'s own list, it therefore redirects the
            // pointers while leaving the buffer's actual allocation — the one
            // every accessor reads from — untouched and full of zeros. Capture
            // then looks perfect and every sample is silent.
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0,
                  let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData
            else { return }

            let available = CMBlockBufferGetDataLength(blockBuffer)
            let capacity = Int(frames) * bytesPerFrame
            let length = min(available, capacity)
            guard length > 0,
                  CMBlockBufferCopyDataBytes(blockBuffer,
                                             atOffset: 0,
                                             dataLength: length,
                                             destination: destination) == noErr
            else { return }

            buffer.frameLength = AVAudioFrameCount(length / bytesPerFrame)
            buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(length)

            onBuffer(buffer)
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch "
            + "interleaved=\(format.isInterleaved) common=\(format.commonFormat.rawValue)"
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

        // Cleared first. If the teardown below hangs, this recording is over as
        // far as the rest of the object is concerned, and the next `start()`
        // must not mistake a dead session for a live one.
        isRunning = false

        tearDownSessionOnQueue()

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
        guard isCurrent(generation) else {
            reportDropOnce("tap fired for an abandoned engine (generation \(generation))")
            return
        }

        lock.lock()
        let first = !reportedFirstBuffer
        reportedFirstBuffer = true
        lock.unlock()

        if first {
            onDiagnostic?("capture: first buffer after \(String(format: "%.3f", secondsSinceAudio)) s, "
                          + "\(Self.describe(buffer.format)) frames=\(buffer.frameLength)")
        }

        appendConverted(buffer, to: targetFormat)
    }

    /// Reports the first way audio was lost in this recording and then stays
    /// quiet, because the tap fires many times a second.
    private func reportDropOnce(_ reason: String) {
        lock.lock()
        let alreadyReported = reportedDrop
        reportedDrop = true
        lock.unlock()

        guard !alreadyReported else { return }
        onDiagnostic?("capture: DROPPING AUDIO — \(reason)")
    }

    func appendConverted(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) {
        guard buffer.frameLength > 0 else {
            reportDropOnce("tap delivered an empty buffer")
            return
        }
        guard let converter = converter(from: buffer.format, to: targetFormat) else {
            reportDropOnce("no converter from \(Self.describe(buffer.format)) "
                           + "to \(Self.describe(targetFormat))")
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            reportDropOnce("could not allocate a \(capacity) frame output buffer")
            return
        }

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

        guard conversionError == nil else {
            reportDropOnce("conversion failed: \(conversionError!)")
            return
        }
        guard output.frameLength > 0 else {
            reportDropOnce("conversion produced no frames from \(buffer.frameLength) in")
            return
        }
        guard let channel = output.floatChannelData else {
            reportDropOnce("converted buffer has no float channel data")
            return
        }

        let frameCount = Int(output.frameLength)
        let converted = Array(UnsafeBufferPointer(start: channel[0], count: frameCount))

        var sumOfSquares: Float = 0
        for sample in converted {
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frameCount)).squareRoot()

        // Bit-exact zero is what a headset produces while it is still leaving
        // its music profile. Anything else, however quiet, means the microphone
        // is genuinely live.
        let audible = converted.contains { $0 != 0 }

        lock.lock()
        let firstAudible = audible && !heardAudio
        let silentSeconds = Double(samples.count) / Self.targetSampleRate

        if firstAudible {
            // Everything captured up to here is the device warming up: buffers
            // of bit-exact silence, worth nothing to the transcriber and
            // actively misleading in the timer, which would start counting from
            // however long the headset took to wake. Dropping it starts the
            // recording where the audio does.
            samples.removeAll()
            levels.removeAll()
        }
        if audible { heardAudio = true }
        lastAudioUptime = DispatchTime.now().uptimeNanoseconds
        samples.append(contentsOf: converted)
        level = rms
        levels.append(rms)
        if levels.count > Self.levelHistoryLength {
            levels.removeFirst(levels.count - Self.levelHistoryLength)
        }
        lock.unlock()

        if firstAudible {
            onDiagnostic?(String(format: "capture: first audible sample after %.3f s of silence, "
                                 + "which was discarded", silentSeconds))
        }
    }
}
