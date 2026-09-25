import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Runs transcript cleanup on the language model built into macOS.
///
/// The alternative to `EmbeddedCleaner` for users who do not want a 3.5 GB
/// download: the system model is already on disk, is loaded by the operating
/// system rather than this process, and costs nothing to keep available.
///
/// Measured on 2026-09-25 on macOS 27.0 with the same prompt, glossary and guard
/// as the embedded model, against the `cleanupcheck` cases: 2 of 4 defects fixed
/// with no damage, about 1.2 s per transcript. The embedded model fixed 3 of 4.
/// The difference is Russian: asked to correct a Russian transcript, this model
/// translates it into English. The vocabulary guard refuses that output, so the
/// transcript is returned unchanged rather than damaged, but the fix is lost.
/// On macOS 26.x, on 2026-08-04, it fixed one defect in six and rewrote
/// `postgres` as `PostgreSQL`, so results depend on the operating system version.
public struct SystemModelCleaner: Sendable {

    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(reason: String)

        public var description: String {
            switch self {
            case .available: "Ready"
            case .unavailable(let reason): reason
            }
        }
    }

    public enum CleanerError: LocalizedError {
        case unavailable(String)
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .emptyReply: "The Apple Intelligence model returned nothing."
            }
        }
    }

    /// Whether the system model can be used right now.
    ///
    /// Checked on every call rather than cached: the user can turn Apple
    /// Intelligence on or off, and the model can finish downloading, while the
    /// app is running.
    public static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable(reason: "This Mac does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable(reason: "Apple Intelligence is turned off in System Settings.")
            case .unavailable(.modelNotReady):
                return .unavailable(reason: "The Apple Intelligence model is still downloading.")
            case .unavailable:
                return .unavailable(reason: "Apple Intelligence is not available.")
            }
        }
        #endif
        return .unavailable(reason: "Requires macOS 26 or later.")
    }

    /// Generation ceiling, as for the embedded model: a cleanup returns the
    /// sentence it was given, so a much longer reply is prose, not an answer.
    public var maximumTokens: Int

    public init(maximumTokens: Int = 600) {
        self.maximumTokens = maximumTokens
    }

    /// Cleans one transcript.
    ///
    /// Throws when the model is unavailable, refuses the input (its safety
    /// guardrails or an unsupported language), or returns nothing. Callers are
    /// expected to fall back to the original transcript.
    public func clean(_ text: String, glossary: [String]) async throws -> CleanupResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .unavailable(let reason) = Self.availability {
                throw CleanerError.unavailable(reason)
            }

            let started = Date()
            // A fresh session per transcript: a shared one would carry earlier
            // dictations in its context, and the model would start drawing on them.
            let session = LanguageModelSession()
            let reply = try await session.respond(
                to: ModelOutput.prompt(for: text, glossary: glossary),
                options: GenerationOptions(
                    samplingMode: .greedy,
                    maximumResponseTokens: maximumTokens
                )
            ).content

            guard let result = ModelOutput.result(
                reply: reply,
                original: text,
                glossary: glossary,
                mode: .appleModel,
                started: started
            ) else { throw CleanerError.emptyReply }
            return result
        }
        #endif
        throw CleanerError.unavailable(Self.availability.description)
    }
}
