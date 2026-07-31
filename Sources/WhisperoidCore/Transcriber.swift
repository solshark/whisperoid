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
    public static let modelVariant = "openai_whisper-large-v3-v20240930_turbo"

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

    public func load(storageDirectory: URL) async throws {
        guard currentPipe() == nil else { return }

        let config = WhisperKitConfig(
            model: Self.modelVariant,
            downloadBase: storageDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        setPipe(try await WhisperKit(config))
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
