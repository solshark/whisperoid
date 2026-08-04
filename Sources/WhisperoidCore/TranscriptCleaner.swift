import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// How a transcript is post-processed before it is injected.
///
/// This is an evaluation feature. Both cleanup modes are off by default and the
/// model mode depends on a local Ollama server that is not shipped with the
/// app, so a user who never opens Settings is unaffected by any of it.
public enum CleanupMode: String, CaseIterable, Sendable, Identifiable {
    case off
    case spelling
    case model

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .spelling: "Spelling (macOS)"
        case .model: "Language model (experimental)"
        }
    }
}

/// The outcome of a cleanup pass.
///
/// `original` is carried alongside `text` because the point of this feature is
/// to be judged in real use: without both, there is no way to tell whether a
/// cleanup helped, and a silent rewrite is exactly the failure mode being
/// guarded against.
public struct CleanupResult: Sendable {
    public let text: String
    public let original: String
    public let mode: CleanupMode
    public let duration: TimeInterval
    /// Set when a candidate replacement was refused, naming what was rejected.
    /// Reported rather than hidden so a guard firing constantly is visible.
    public let rejected: [String]

    public var changed: Bool { text != original }

    public init(
        text: String,
        original: String,
        mode: CleanupMode,
        duration: TimeInterval = 0,
        rejected: [String] = []
    ) {
        self.text = text
        self.original = original
        self.mode = mode
        self.duration = duration
        self.rejected = rejected
    }

    /// The transcript unchanged. Used whenever cleanup is off, unavailable or
    /// fails: a cleanup problem must never cost the user their dictation.
    public static func untouched(_ text: String, mode: CleanupMode = .off) -> CleanupResult {
        CleanupResult(text: text, original: text, mode: mode)
    }
}

// MARK: - Spelling

/// Corrects a transcript using the macOS spelling service.
///
/// `AppleSpell` is already resident system-wide, so this costs no memory and
/// needs no download. It covers 43 languages including Russian.
///
/// **It is only ever allowed to split a word or change its case.** Asked to
/// correct technical vocabulary the spelling service is actively destructive —
/// measured on 2026-08-04 it turns `Postgre` into `Poster`, `Kolyma` into
/// `Cholera` and `Колема` into `Колеса`. Those are all substitutions, and
/// substitutions are refused here regardless of how confident the suggestion
/// is. What survives the rule is genuinely useful: `muchmemory` becomes
/// `much memory`, which is the defect this mode exists to fix.
public struct SpellingCleaner: Sendable {

    public init() {}

    /// Whether a suggestion may be applied.
    ///
    /// Accepted when removing spaces from the suggestion reproduces the original
    /// word, ignoring case and diacritics. That admits exactly three safe
    /// transformations — inserting a space, changing case, and restoring a
    /// diacritic (`undersoge` → `undersøge`) — and rejects every substitution,
    /// because a different word cannot have the same letters.
    public static func isSafeReplacement(_ suggestion: String, for original: String) -> Bool {
        let collapsed = suggestion.replacingOccurrences(of: " ", with: "")
        guard collapsed.count == original.count else { return false }
        return collapsed.compare(
            original,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }

    #if canImport(AppKit)
    /// Applies safe corrections to `text`.
    ///
    /// `language` is the code the transcriber detected, which is more reliable
    /// than asking the spell checker to identify the language of a short,
    /// possibly defective transcript.
    @MainActor
    public func clean(_ text: String, language: String) -> CleanupResult {
        let started = Date()
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var corrections: [(NSRange, String)] = []
        var rejected: [String] = []
        var location = 0

        while location < ns.length {
            let range = checker.checkSpelling(
                of: text,
                startingAt: location,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            location = range.location + range.length

            let word = ns.substring(with: range)
            let guesses = checker.guesses(
                forWordRange: range,
                in: text,
                language: language,
                inSpellDocumentWithTag: 0
            ) ?? []

            // Only the first suggestion that passes the rule is considered.
            // Hunting further down the list for something acceptable would mean
            // preferring a low-confidence guess purely because it is a legal
            // shape, which is how a plausible wrong answer gets in.
            if let best = guesses.first, Self.isSafeReplacement(best, for: word) {
                corrections.append((range, best))
            } else if let best = guesses.first {
                rejected.append("\(word) → \(best)")
            }
        }

        // Applied last-first so earlier ranges stay valid as the string changes.
        var out = text
        for (range, replacement) in corrections.reversed() {
            out = (out as NSString).replacingCharacters(in: range, with: replacement)
        }

        return CleanupResult(
            text: out,
            original: text,
            mode: .spelling,
            duration: Date().timeIntervalSince(started),
            rejected: rejected
        )
    }
    #endif
}

// MARK: - Language model

/// Corrects a transcript with a local language model served by Ollama.
///
/// Experimental and deliberately not self-contained: it talks to a server the
/// user installs separately. Shipping this would require in-process inference,
/// and that decision is not made yet — this exists so the two approaches can be
/// compared in real use rather than on invented sentences.
///
/// Measured with `gemma3:4b` on 2026-08-04: 4 of 6 defects fixed, no damage,
/// 1.4 s warm, 2.1 s from cold, 4.3 GB resident while loaded.
public struct ModelCleaner: Sendable {

    public struct Configuration: Sendable {
        public var endpoint: URL
        public var model: String
        public var glossary: [String]
        public var timeout: TimeInterval
        /// How long Ollama keeps the model in memory after a request. Short by
        /// default so 4.3 GB is held during a dictation session and released
        /// afterwards rather than sitting resident all day.
        public var keepAlive: String

        public init(
            endpoint: URL = URL(string: "http://127.0.0.1:11434/api/chat")!,
            model: String = "gemma3:4b",
            glossary: [String] = Configuration.defaultGlossary,
            timeout: TimeInterval = 20,
            keepAlive: String = "2m"
        ) {
            self.endpoint = endpoint
            self.model = model
            self.glossary = glossary
            self.timeout = timeout
            self.keepAlive = keepAlive
        }

        /// Without a glossary every model tested scored 1 fix in 6; with one the
        /// best scored 4 to 6. The model is not recalling this vocabulary, it is
        /// matching against the list — so the list, not the model, is what makes
        /// this mode work. List one spelling per term: an early version offered
        /// both `Postgres` and `PostgreSQL` and the models read that as an
        /// instruction to swap one for the other.
        public static let defaultGlossary = [
            "Colima", "Claude Code", "Postgres", "WhisperKit", "MLX", "Whisperoid",
            "Ollama", "Gemma", "Qwen", "Docker", "Prezentor", "GitLab", "Core ML",
            "Swift", "Xcode", "MinIO", "Celery", "Redis", "Kubernetes", "Homebrew",
        ]
    }

    public enum CleanerError: LocalizedError {
        case unavailable
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .unavailable: "The local model server did not respond."
            case .emptyReply: "The local model returned nothing."
            }
        }
    }

    public let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.timeout
        self.session = URLSession(configuration: config)
    }

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

        The transcript may render these terms phonetically, including \
        transliterated into a different alphabet — a Latin product name written \
        in Cyrillic, for example. Restore the term to the exact spelling listed \
        below, in its original alphabet, regardless of the language of the \
        surrounding sentence:
        \(glossary.joined(separator: ", "))

        <text>
        \(text)
        </text>

        Put the corrected transcript inside <corrected> tags. Output nothing else.
        """
    }

    public func clean(_ text: String) async throws -> CleanupResult {
        let started = Date()
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [["role": "user",
                          "content": Self.prompt(for: text, glossary: configuration.glossary)]],
            "stream": false,
            "think": false,
            "keep_alive": configuration.keepAlive,
            // 2048 covers a dictation turn. Raising it does not improve results
            // and does increase what Ollama reserves.
            "options": ["temperature": 0.0, "num_predict": 2048, "num_ctx": 2048],
        ])

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw CleanerError.unavailable
        }

        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = payload["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw CleanerError.emptyReply
        }

        let candidate = Self.extract(content)
        guard !candidate.isEmpty else { throw CleanerError.emptyReply }

        let guarded = VocabularyGuard.check(
            original: text,
            candidate: Self.normalise(candidate),
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

    /// Pulls the reply out of the `<corrected>` tags the prompt asks for.
    /// Smaller models routinely open the tag and never close it.
    static func extract(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.range(of: "<corrected>", options: .caseInsensitive) {
            let rest = text[open.upperBound...]
            if let close = rest.range(of: "</corrected>", options: .caseInsensitive) {
                return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Undoes typographic substitutions the model makes unasked.
    ///
    /// `gemma3:1b` and `gemma3:4b` both replace `'` with `’`. Dictated text is
    /// routinely typed into editors and terminals, where a curly apostrophe is
    /// a syntax error rather than a nicety.
    static func normalise(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }
}

// MARK: - Vocabulary guard

/// Rejects model output that contains words the speaker did not say.
///
/// A similarity threshold was tried first and does not work: across 126
/// measured results, harmful and helpful edits overlap almost completely
/// (harmful median 0.913, helpful median 0.957), because swapping a word
/// wrongly and fixing a word correctly are the same size of edit.
///
/// This asks a different question — where did each output word come from? A
/// word is legitimate if it was in the transcript, is a fragment of a word in
/// the transcript (so splitting `muchmemory` is allowed), or is a glossary term
/// (so `Kolyma` → `Colima` is allowed). Anything else was invented.
public enum VocabularyGuard {

    public struct Verdict: Sendable {
        public let accepted: Bool
        public let text: String
        public let reasons: [String]
    }

    public static func check(
        original: String,
        candidate: String,
        glossary: [String]
    ) -> Verdict {
        let source = Set(words(in: original).map { $0.lowercased() })
        let allowed = Set(glossary.flatMap { words(in: $0) }.map { $0.lowercased() })

        for word in words(in: candidate) {
            let lower = word.lowercased()
            if source.contains(lower) || allowed.contains(lower) { continue }
            if source.contains(where: { $0.count > lower.count && $0.contains(lower) }) { continue }
            return Verdict(accepted: false, text: original, reasons: ["invented “\(word)”"])
        }

        // Deletion is the guard's weak side: it can only police terms it knows
        // about, so a dropped ordinary word passes. Glossary terms are at least
        // held to account, since those are the ones worth protecting.
        let result = Set(words(in: candidate).map { $0.lowercased() })
        for term in allowed where source.contains(term) && !result.contains(term) {
            return Verdict(accepted: false, text: original, reasons: ["dropped “\(term)”"])
        }

        return Verdict(accepted: true, text: candidate, reasons: [])
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
