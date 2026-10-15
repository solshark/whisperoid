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
        /// Size of the glossary prompt the model was given, zero when none was.
        /// Logged so a transcript can be attributed to the setting that made it.
        public var promptTokens: Int = 0
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

    /// Shown before a download when the model host cannot be asked for the
    /// exact size. True of the default variant only.
    public static let approximateDownloadSize = "about 1.6 GB"

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

    /// Core ML components that must be present for the model to be usable.
    /// `TextDecoderContextPrefill` is deliberately excluded; not every variant
    /// ships one.
    private static let requiredComponents = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]

    /// Returns the model folder when it already holds a usable model.
    ///
    /// Checked against the actual Core ML payload inside each component rather
    /// than mere directory existence, so a partial or interrupted download is
    /// correctly treated as absent and fetched again.
    public static func localModel(in storageDirectory: URL) -> URL? {
        let folder = modelFolder(in: storageDirectory)
        let manager = FileManager.default

        guard manager.fileExists(atPath: folder.appendingPathComponent("config.json").path) else {
            return nil
        }
        for component in requiredComponents {
            let payload = folder
                .appendingPathComponent("\(component).mlmodelc", isDirectory: true)
                .appendingPathComponent("coremldata.bin")
            guard manager.fileExists(atPath: payload.path) else { return nil }
        }
        return folder
    }

    /// Where the model files are expected on disk, whether or not they exist.
    public static func modelFolder(in storageDirectory: URL) -> URL {
        repositoryFolder(in: storageDirectory)
            .appendingPathComponent(modelVariant, isDirectory: true)
    }

    private static func repositoryFolder(in storageDirectory: URL) -> URL {
        storageDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelRepository, isDirectory: true)
    }

    /// Every folder a download of the current variant writes to, including
    /// files still in transit.
    ///
    /// The downloader streams each file into `.cache/huggingface/download`
    /// under the repository folder and moves it into the model folder only once
    /// it is complete. Measuring the model folder alone therefore sees nothing
    /// of the file in flight, which for the audio encoder is 1.3 GB of a
    /// 1.6 GB download.
    ///
    /// The cache folder also holds the downloader's small `.metadata` files, so
    /// a finished download measures a few hundred bytes over the size the model
    /// host reports: 451 bytes on 2026-10-15. Progress is clamped at complete,
    /// so this never shows.
    public static func downloadFolders(in storageDirectory: URL) -> [URL] {
        [
            modelFolder(in: storageDirectory),
            repositoryFolder(in: storageDirectory)
                .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
                .appendingPathComponent(modelVariant, isDirectory: true),
        ]
    }

    /// Bytes the current variant's download has put on disk so far.
    public static func downloadedBytes(in storageDirectory: URL) -> Int64 {
        downloadFolders(in: storageDirectory).reduce(0) {
            $0 + Diagnostics.directorySize(at: $1)
        }
    }

    public func load(
        storageDirectory: URL,
        onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws {
        guard currentPipe() == nil else { return }

        onPhase(.locating)

        // Skip the network entirely when the model is already on disk. The
        // download call reaches the remote API before it consults anything
        // local, so without this the app cannot start while offline, or if the
        // model host is unreachable, despite holding a complete copy.
        let folder: URL
        if let cached = Self.localModel(in: storageDirectory) {
            folder = cached
        } else {
            // Downloading is done explicitly rather than letting the WhisperKit
            // initialiser do it, so progress is observable and a stalled
            // transfer can be told apart from model preparation.
            folder = try await WhisperKit.download(
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
        }

        onPhase(.preparing)

        let config = WhisperKitConfig(
            model: Self.modelVariant,
            modelFolder: folder.path,
            // Without this the tokenizer resolves against HubApi's default,
            // which is ~/Documents/huggingface. It would be downloaded again
            // to a directory the app does not own, and would not be found
            // locally on a machine that is offline.
            tokenizerFolder: storageDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        setPipe(try await WhisperKit(config))

        onPhase(.ready)
    }

    /// The sentence given to the model as its prompt, built from the glossary.
    ///
    /// Whisper treats a prompt as text that preceded the recording, so the
    /// terms are written as a punctuated sentence: the model copies both the
    /// spelling of the terms and the style of the prose. Measured on
    /// 2026-09-25 with WhisperKit 1.1.0, this corrected `Cloud Code`, `Kolyma`
    /// and the Cyrillic `Колема` in the recording itself, with no prompt text
    /// appearing in the output for silence, noise or very short clips.
    public static func prompt(for glossary: [String]) -> String? {
        let terms = glossary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = terms.last else { return nil }
        guard terms.count > 1 else { return "We use \(last)." }
        return "We use \(terms.dropLast().joined(separator: ", ")) and \(last)."
    }

    /// Whisper's prompt occupies at most half of its 448-token text context.
    /// Anything past this would be discarded by the model, or crowd out the
    /// transcript itself.
    static let maximumPromptTokens = 200

    /// Options for every transcription, before any glossary prompt is added.
    ///
    /// Recordings longer than the model's 30-second window are split at pauses
    /// (`.vad`) and each piece is transcribed on its own. Without this they are
    /// decoded as consecutive fixed windows, which loses speech in two ways,
    /// both measured on 2026-10-05 against recordings with known text:
    ///
    /// - Text near the end of a window is dropped when the model stops before
    ///   the window does, because the next window starts at the fixed boundary
    ///   regardless. Word recall on a 33-second recording rose from 0.77 to 0.96.
    /// - With a glossary prompt, a later window can come back empty and the
    ///   language can be misdetected. A 60-second recording lost up to half its
    ///   words, inconsistently between runs.
    ///
    /// Recordings within one window are not chunked, so this changes nothing
    /// for short dictation.
    static func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
    }

    public func transcribe(samples: [Float], glossary: [String] = []) async throws -> Output {
        guard let pipe = currentPipe() else { throw TranscriberError.notLoaded }

        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        guard seconds >= Self.minimumSeconds else { throw TranscriberError.tooShort }

        var options = Self.decodingOptions()

        // Requires WhisperKit 1.1 or later: on 0.18 any prompt produced empty
        // output on this model variant.
        if let prompt = Self.prompt(for: glossary), let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(Self.maximumPromptTokens))
        }

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
            duration: elapsed,
            promptTokens: options.promptTokens?.count ?? 0
        )
    }
}
