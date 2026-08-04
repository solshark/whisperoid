import Foundation
import Hub
import MLX
import MLXLMCommon
import MLXLLM
import Tokenizers

/// Runs transcript cleanup on a language model inside this process.
///
/// Replaces the earlier Ollama-backed cleaner. That worked, but required the
/// user to install and run a separate server, which an app cannot rely on.
///
/// Uses `mlx-community/gemma-4-e2b-it-4bit`, chosen by measurement on
/// 2026-08-04 (see `spike/cleanup/README.md`): 4 of 6 defects fixed with no
/// damage, 0.7 s per transcript, 3.55 GB of weights, and it corrects Russian
/// jargon that Gemma 3 4B missed and only a 9.8 GB model previously managed.
/// Gemma 4 is Apache 2.0, unlike Gemma 3.
///
/// Gemma 4 E-series accepts audio and images as well as text, but only text is
/// ever sent, so it is loaded through `LLMRegistry` rather than `VLMRegistry`.
/// That skips the vision and audio towers, and avoids a defect in the VLM
/// wrapper: E2B shares key/value projections across its last 20 layers, and the
/// VLM path tries to load a `k_proj` for layers that do not carry one.
public actor EmbeddedCleaner {

    /// What the model is doing, so a first run that downloads several gigabytes
    /// is distinguishable from one that has stalled. Mirrors
    /// `Transcriber.Phase`, which solves the same problem for the speech model.
    public enum Phase: Sendable, Equatable {
        case idle
        /// Progress is counted in *files*, not bytes — the same trap the speech
        /// model download has. The model is a handful of files of wildly
        /// different sizes, one of which is most of the 3.5 GB, so the
        /// percentage jumps and then sits still for a very long time. Reported
        /// as a file count so the figure at least matches what it measures.
        case downloading(fraction: Double, completedFiles: Int64, totalFiles: Int64)
        case preparing
        case ready

        public var description: String {
            switch self {
            case .idle:
                "Not loaded"
            case .downloading(let fraction, let completedFiles, let totalFiles):
                totalFiles > 0
                    ? String(format: "Downloading cleanup model… file %d of %d (%.0f%%)",
                             completedFiles, totalFiles, fraction * 100)
                    : String(format: "Downloading cleanup model… %.0f%%", fraction * 100)
            case .preparing:
                "Preparing cleanup model…"
            case .ready:
                "Ready"
            }
        }
    }

    public struct Configuration: Sendable {
        public var glossary: [String]
        /// Generation ceiling. A cleanup returns the same sentence it was given,
        /// so anything much beyond the input length means the model has started
        /// writing prose instead of answering.
        public var maximumTokens: Int

        public init(
            glossary: [String] = ModelCleaner.Configuration.defaultGlossary,
            maximumTokens: Int = 600
        ) {
            self.glossary = glossary
            self.maximumTokens = maximumTokens
        }
    }

    public enum CleanerError: LocalizedError {
        case notLoaded
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .notLoaded: "The cleanup model has not finished loading."
            case .emptyReply: "The cleanup model returned nothing."
            }
        }
    }

    public static let modelIdentifier = "mlx-community/gemma-4-e2b-it-4bit"

    private var container: ModelContainer?
    private let storageDirectory: URL

    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    public var isLoaded: Bool { container != nil }

    /// Downloads the model if needed and loads it into memory.
    ///
    /// Safe to call repeatedly; returns immediately when already loaded.
    public func load(onPhase: @escaping @Sendable (Phase) -> Void) async throws {
        if container != nil { return }

        let downloader = HubModelDownloader(storageDirectory: storageDirectory)
        onPhase(.preparing)

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: TransformersTokenizerLoader(),
            configuration: LLMRegistry.gemma4_e2b_it_4bit
        ) { progress in
            onPhase(
                .downloading(
                    fraction: progress.fractionCompleted,
                    completedFiles: progress.completedUnitCount,
                    totalFiles: progress.totalUnitCount
                )
            )
        }

        container = loaded
        onPhase(.ready)
    }

    /// Drops the model and releases its memory.
    ///
    /// Reloading from a warm cache is around 2.7 s, so holding several gigabytes
    /// through a long idle period buys very little. The MLX buffer cache is
    /// cleared too; without that the allocator keeps the arena and the memory is
    /// not returned to the system.
    public func unload() {
        container = nil
        MLX.Memory.clearCache()
    }

    public func clean(_ text: String, configuration: Configuration) async throws -> CleanupResult {
        guard let container else { throw CleanerError.notLoaded }

        let started = Date()
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(
                maxTokens: configuration.maximumTokens,
                temperature: 0.0
            )
        )

        let reply = try await session.respond(
            to: Self.prompt(for: text, glossary: configuration.glossary)
        )

        let candidate = ModelCleaner.extract(reply)
        guard !candidate.isEmpty else { throw CleanerError.emptyReply }

        let guarded = VocabularyGuard.check(
            original: text,
            candidate: ModelCleaner.normalise(candidate),
            glossary: configuration.glossary
        )

        return CleanupResult(
            text: guarded.accepted ? guarded.text : text,
            original: text,
            mode: .model,
            duration: Date().timeIntervalSince(started),
            rejected: guarded.reasons
        )
    }

    /// Wording measured against the same six cases as every other candidate.
    /// The transliteration sentence is what lets a single glossary entry cover
    /// mishearings across alphabets, so `Colima` also catches `Колема`.
    static func prompt(for text: String, glossary: [String]) -> String {
        """
        Correct the speech-to-text transcript inside the <text> tags.

        Rules:
        - Fix missing spaces, missing or wrong punctuation, and wrong capitalisation.
        - Fix words that were clearly misheard by the speech-to-text system.
        - Do NOT rephrase. Do NOT expand abbreviations or product names.
        - Do NOT add, remove or reorder any content.
        - Reply in the same language as the input.
        - If nothing is wrong, repeat the text unchanged.

        The speaker often uses these terms and the speech-to-text system mishears \
        them, sometimes phonetically and sometimes transliterated into another \
        alphabet. Restore the exact spelling listed below whenever the context \
        matches, in its original alphabet, regardless of the surrounding language. \
        Product names are often heard as ordinary words that sound similar:
        \(glossary.joined(separator: ", "))

        <text>
        \(text)
        </text>

        Put the corrected transcript inside <corrected> tags. Output nothing else.
        """
    }
}

// MARK: - Hugging Face bridging

/// Bridges MLX's `Downloader` onto the Hugging Face client already in this app.
///
/// MLX ships macros that build this automatically, but they expand to code
/// referencing `HubClient`, a type from a newer swift-transformers than the one
/// WhisperKit pins. Conforming directly is the documented alternative and keeps
/// both packages on the single `swift-transformers` version already resolved.
struct HubModelDownloader: Downloader {

    let storageDirectory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // Kept beside the speech model rather than in the Hugging Face default
        // of ~/Documents/huggingface, which the app does not own and which is
        // surprising to find several gigabytes in.
        let hub = HubApi(downloadBase: storageDirectory)
        return try await hub.snapshot(
            from: Hub.Repo(id: id, type: .models),
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// Loads a tokenizer with swift-transformers and adapts it to MLX's protocol.
struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: tokenizer)
    }
}

/// Adapts `Tokenizers.Tokenizer` to `MLXLMCommon.Tokenizer`.
struct TokenizerBridge: MLXLMCommon.Tokenizer {

    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // swift-transformers takes `[[String: String]]`, so the values are
        // flattened. Cleanup sends a single plain-text user turn, which loses
        // nothing in the conversion.
        let flattened = messages.map { message in
            message.compactMapValues { $0 as? String }
        }
        return try upstream.applyChatTemplate(messages: flattened)
    }
}
