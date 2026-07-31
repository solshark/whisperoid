import Foundation
import WhisperKit

/// Wraps WhisperKit. The model is loaded once at launch and stays resident for
/// the lifetime of the app, so no Whisper process outlives the application.
///
/// This is a lock-guarded class rather than an actor because `WhisperKit` is a
/// non-Sendable class whose `transcribe` is nonisolated; holding it inside an
/// actor makes every call a cross-isolation send. Callers are expected to run
/// one transcription at a time, which the app's state machine guarantees.
public final class Transcriber: @unchecked Sendable {

    /// Startup is split into distinct phases because they fail and stall for
    /// entirely different reasons. A single "loading" state cannot distinguish
    /// a stalled download from Core ML compiling the model for a new machine,
    /// which is CPU-bound, can take minutes on first run, and shows no network
    /// activity at all.
    public enum Phase: Sendable, Equatable {
        case locating
        /// Progress is counted in *files*, not bytes. The model is a handful of
        /// files of wildly different sizes, so this figure jumps and then sits
        /// still for hundreds of megabytes; on-disk size is the honest measure
        /// of movement and is reported alongside it.
        case downloading(fraction: Double, completedFiles: Int64, totalFiles: Int64)
        case preparing
        case ready

        public var description: String {
            switch self {
            case .locating:
                "Finding model…"
            case .downloading(let fraction, let completedFiles, let totalFiles):
                totalFiles > 0
                    ? String(format: "Downloading model… file %d of %d (%.0f%%)",
                             completedFiles, totalFiles, fraction * 100)
                    : String(format: "Downloading model… %.0f%%", fraction * 100)
            case .preparing:
                "Preparing model…"
            case .ready:
                "Ready"
            }
        }
    }

    public struct Output: Sendable {
        public let text: String
        public let language: String
        public let duration: TimeInterval
    }

    public enum TranscriberError: LocalizedError {
        case notLoaded
        case tooShort

        public var errorDescription: String? {
            switch self {
            case .notLoaded: "The speech model has not finished loading."
            case .tooShort: "That recording was too short to transcribe."
            }
        }
    }

    /// Benchmarked as the best combination of latency and reliable language
    /// auto-detection on Apple Silicon.
    ///
    /// Note the naming: WhisperKit's `_turbo` suffix denotes its own Neural
    /// Engine optimisation, not OpenAI's turbo model. The `v20240930` part is
    /// what makes this large-v3-turbo, the variant with 4 decoder layers.
    /// `openai_whisper-large-v3_turbo` is the full 1.5B model and is roughly
    /// four times slower with markedly worse language detection.
    /// `WHISPEROID_MODEL_VARIANT` overrides this, which allows the download and
    /// preparation path to be exercised with a small model.
    public static var modelVariant: String {
        let override = ProcessInfo.processInfo.environment["WHISPEROID_MODEL_VARIANT"]
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? defaultModelVariant
    }

    public static let defaultModelVariant = "openai_whisper-large-v3-v20240930_turbo"

    public static let modelRepository = "argmaxinc/whisperkit-coreml"

    /// Anything shorter than this is almost always an accidental double-tap.
    public static let minimumSeconds: Double = 0.3

    private let lock = NSLock()
    private var pipe: WhisperKit?

    public init() {}

    public var isLoaded: Bool { currentPipe() != nil }

    private func currentPipe() -> WhisperKit? {
        lock.lock()
        defer { lock.unlock() }
        return pipe
    }

    private func setPipe(_ value: WhisperKit) {
        lock.lock()
        defer { lock.unlock() }
        pipe = value
    }

    /// Where the model files are expected on disk, whether or not they exist.
    public static func modelFolder(in storageDirectory: URL) -> URL {
        storageDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepository, isDirectory: true)
            .appendingPathComponent(modelVariant, isDirectory: true)
    }

    public func load(
        storageDirectory: URL,
        onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws {
        guard currentPipe() == nil else { return }

        onPhase(.locating)

        // Downloading is done explicitly rather than letting the WhisperKit
        // initialiser do it, so progress is observable and a stalled transfer
        // can be told apart from model preparation.
        let folder = try await WhisperKit.download(
            variant: Self.modelVariant,
            downloadBase: storageDirectory,
            from: Self.modelRepository
        ) { progress in
            onPhase(
                .downloading(
                    fraction: progress.fractionCompleted,
                    completedFiles: progress.completedUnitCount,
                    totalFiles: progress.totalUnitCount
                )
            )
        }

        onPhase(.preparing)

        let config = WhisperKitConfig(
            model: Self.modelVariant,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        setPipe(try await WhisperKit(config))

        onPhase(.ready)
    }

    public func transcribe(samples: [Float]) async throws -> Output {
        guard let pipe = currentPipe() else { throw TranscriberError.notLoaded }

        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        guard seconds >= Self.minimumSeconds else { throw TranscriberError.tooShort }

        // Custom vocabulary via `promptTokens` is deliberately not used: it
        // returns empty output on this model variant in WhisperKit 0.18.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let started = Date()
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(started)

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Output(
            text: text,
            language: results.first?.language ?? "??",
            duration: elapsed
        )
    }
}
