import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// How a transcript is post-processed before it is injected.
///
/// Both modes are off by default, and the model mode downloads several
/// gigabytes the first time it is chosen, so a user who never opens Settings is
/// unaffected by any of it.
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

// MARK: - Model output

/// Shared handling of a language model's reply.
///
/// Kept apart from the model that produced it: the parsing and the repairs
/// below are properties of what these models do to text, not of how they are
/// hosted. They outlived an earlier Ollama-backed cleaner and would outlive
/// this one.
public enum ModelOutput {

    /// Terms the model should recognise.
    ///
    /// Without a glossary every model tested corrected roughly one defect in
    /// six; with one, four to six. The model is not recalling this vocabulary,
    /// it is matching against the list, so the list is what makes the feature
    /// work. List one spelling per term: an early version offered both
    /// `Postgres` and `PostgreSQL`, and the models read that as an instruction
    /// to swap one for the other.
    ///
    /// These are deliberately generic developer tools. Names specific to your
    /// own work — colleagues, employers, internal services — are what the
    /// glossary is really for, and they belong in Settings rather than here.
    public static let defaultGlossary = [
        "Colima", "Claude Code", "Postgres", "WhisperKit", "MLX", "Whisperoid",
        "Gemma", "Docker", "GitLab", "Core ML", "Swift", "Xcode",
        "MinIO", "Celery", "Redis", "Kubernetes", "Homebrew",
    ]

    /// Pulls the reply out of the `<corrected>` tags the prompt asks for.
    /// Smaller models routinely open the tag and never close it.
    public static func extract(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.range(of: "<corrected>", options: .caseInsensitive) {
            let rest = text[open.upperBound...]
            if let close = rest.range(of: "</corrected>", options: .caseInsensitive) {
                return String(rest[..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Undoes formatting the model applies unasked.
    ///
    /// Two observed habits, both destructive for dictation. The models replace
    /// `'` with a curly apostrophe, which is a syntax error in the editors and
    /// terminals this text is typed into. They also emphasise words they
    /// consider significant, turning "stop Ollama service" into markdown the
    /// speaker never uttered — which the vocabulary guard cannot catch, because
    /// the word survives and only the punctuation around it is new.
    ///
    /// Asterisks are removed unconditionally: speech has no way to produce one,
    /// so any that appear were invented. Underscores are left alone, since they
    /// occur in identifiers the speaker may genuinely be dictating.
    public static func normalise(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "*", with: "")
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
