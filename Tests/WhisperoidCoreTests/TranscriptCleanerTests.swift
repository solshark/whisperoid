import Foundation
import Testing

@testable import WhisperoidCore

/// Covers the rule that keeps transcript cleanup from destroying the words the
/// speaker actually said.
///
/// The measurements behind these cases are in `spike/cleanup/README.md`. The
/// short version: the macOS spelling service, asked to correct technical
/// vocabulary, turns `Postgre` into `Poster` and `Kolyma` into `Cholera`. Those
/// are confident, well-formed suggestions, so nothing about the API's own
/// output signals that they are wrong. The only defence is refusing
/// substitutions categorically, which is what these tests pin down.
struct SpellingCleanerSafetyTests {

    @Test("A run-together word may be split")
    func acceptsSplit() {
        #expect(SpellingCleaner.isSafeReplacement("much memory", for: "muchmemory"))
        #expect(SpellingCleaner.isSafeReplacement("like that", for: "likethat"))
        #expect(SpellingCleaner.isSafeReplacement("this is", for: "thisis"))
    }

    @Test("Capitalisation of a product name may be corrected")
    func acceptsCaseChange() {
        #expect(SpellingCleaner.isSafeReplacement("Postgres", for: "postgres"))
        #expect(SpellingCleaner.isSafeReplacement("GitLab", for: "gitlab"))
    }

    @Test("A missing diacritic may be restored")
    func acceptsDiacritic() {
        // Worth having for Russian in particular: the transcriber routinely
        // renders ё as е, and restoring it is a safe, letter-preserving change.
        #expect(SpellingCleaner.isSafeReplacement("перенесём", for: "перенесем"))
        #expect(SpellingCleaner.isSafeReplacement("днём", for: "днем"))
        #expect(SpellingCleaner.isSafeReplacement("café", for: "cafe"))
    }

    @Test("A stroked letter is not treated as a diacritic, so ø is left alone")
    func rejectsStrokedLetter() {
        // Danish ø is its own letter rather than o with a mark, so it does not
        // fold and `undersoge` → `undersøge` is refused. That is a real gap in
        // Nordic coverage, accepted deliberately: widening the rule to admit
        // letter changes is precisely what lets Postgre become Poster.
        #expect(!SpellingCleaner.isSafeReplacement("undersøge", for: "undersoge"))
    }

    @Test("A different word is never substituted, however confident the suggestion")
    func rejectsSubstitution() {
        // Each of these is what NSSpellChecker actually proposes, measured on
        // macOS 26.5.2. Applying any of them destroys the term.
        #expect(!SpellingCleaner.isSafeReplacement("Poster", for: "Postgre"))
        #expect(!SpellingCleaner.isSafeReplacement("Cholera", for: "Kolyma"))
        #expect(!SpellingCleaner.isSafeReplacement("Колеса", for: "Колема"))
        #expect(!SpellingCleaner.isSafeReplacement("Колыма", for: "Колима"))
        #expect(!SpellingCleaner.isSafeReplacement("thesis", for: "thisis"))
    }

    @Test("A hyphen is not a space, so hyphenation is refused")
    func rejectsHyphenation() {
        // NSSpellChecker offers "much-memory" alongside "much memory". Only the
        // spaced form reproduces the original once spaces are removed.
        #expect(!SpellingCleaner.isSafeReplacement("much-memory", for: "muchmemory"))
    }

    @Test("Adding or dropping letters is refused even when the word is close")
    func rejectsLengthChange() {
        #expect(!SpellingCleaner.isSafeReplacement("Postgres", for: "Postgre"))
        #expect(!SpellingCleaner.isSafeReplacement("receive", for: "recieve"))
    }

    @MainActor
    @Test("A clean sentence is returned untouched")
    func leavesCleanTextAlone() {
        let text = "This is a blind test recording."
        let result = SpellingCleaner().clean(text, language: "en")
        #expect(result.text == text)
        #expect(!result.changed)
    }

    @MainActor
    @Test("Run-together words in a real sentence are split")
    func splitsInContext() {
        let result = SpellingCleaner()
            .clean("how muchmemory it will consume and stuff likethat", language: "en")
        #expect(result.text == "how much memory it will consume and stuff like that")
    }

    @MainActor
    @Test("A misheard product name survives a spelling pass intact")
    func doesNotDestroyProductNames() {
        // The whole point of the mode: it must be safe on the words it cannot
        // fix, not merely useful on the ones it can.
        let text = "Let's migrate the postgres container over to Kolyma this afternoon."
        let result = SpellingCleaner().clean(text, language: "en")
        #expect(result.text.contains("Kolyma"))
        #expect(!result.text.contains("Cholera"))
        #expect(result.rejected.allSatisfy { $0.kind == .spelling })
    }

    @MainActor
    @Test("Russian text is not mangled, since the dictionary offers no safe splits")
    func leavesRussianAlone() {
        let text = "Давай перенесем контейнер Postgres на Колема сегодня днем."
        let result = SpellingCleaner().clean(text, language: "ru")
        #expect(result.text.contains("Колема"))
        #expect(!result.text.contains("Колеса"))
    }
}

/// Covers the guard on language-model output.
///
/// A similarity threshold was measured first and rejected: harmful and helpful
/// edits overlap almost completely, because swapping a word wrongly and fixing
/// one correctly are the same size of edit. This guard asks where each output
/// word came from instead.
struct VocabularyGuardTests {

    private let glossary = ["Colima", "Claude Code", "Postgres", "Docker"]

    @Test("Output that lost punctuation is refused")
    func rejectsDroppedPunctuation() {
        // Real dictation, 2026-09-25: the embedded model removed three correct
        // commas from an already punctuated transcript.
        let verdict = VocabularyGuard.check(
            original: "if it will record, recover any formatting, capitalization, question marks maybe. Let's see.",
            candidate: "if it will record recover any formatting capitalization question marks maybe. Let's see.",
            glossary: glossary
        )
        #expect(!verdict.accepted)
        #expect(verdict.reasons.map(\.kind) == [.punctuation])
    }

    @Test("A question mark may not become a full stop")
    func rejectsLostQuestion() {
        let verdict = VocabularyGuard.check(
            original: "What about these Gemma models?",
            candidate: "What about these Gemma models.",
            glossary: glossary
        )
        #expect(!verdict.accepted)
        #expect(verdict.reasons.map(\.kind) == [.punctuation])
    }

    @Test("Punctuation may be added or changed, just not removed")
    func acceptsPunctuationChanges() {
        let added = VocabularyGuard.check(
            original: "so what do you think should we ship this today",
            candidate: "So, what do you think? Should we ship this today?",
            glossary: glossary
        )
        #expect(added.accepted)

        let changed = VocabularyGuard.check(
            original: "we ship today, then rest",
            candidate: "We ship today. Then rest",
            glossary: glossary
        )
        #expect(changed.accepted)
    }

    @Test("A glossary term may replace a mishearing of it")
    func acceptsGlossarySubstitution() {
        let verdict = VocabularyGuard.check(
            original: "migrate the container over to Kolyma today",
            candidate: "migrate the container over to Colima today",
            glossary: glossary
        )
        #expect(verdict.accepted)
    }

    @Test("A word the speaker did not say is refused")
    func rejectsInvention() {
        // The exact failure that disqualified Apple's model and gemma3:4b under
        // an early prompt: postgres silently became PostgreSQL.
        let verdict = VocabularyGuard.check(
            original: "migrate the postgres container",
            candidate: "migrate the PostgreSQL container",
            glossary: glossary
        )
        #expect(!verdict.accepted)
        #expect(verdict.text == "migrate the postgres container")
        #expect(verdict.reasons == [Refusal(kind: .invented, detail: "invented “PostgreSQL”")])
    }

    @Test("Splitting a run-together word is allowed")
    func acceptsSplit() {
        let verdict = VocabularyGuard.check(
            original: "how muchmemory it consumes",
            candidate: "how much memory it consumes",
            glossary: glossary
        )
        #expect(verdict.accepted)
    }

    @Test("Dropping a glossary term is refused")
    func rejectsDeletion() {
        let verdict = VocabularyGuard.check(
            original: "we use Docker for the containers",
            candidate: "we use for the containers",
            glossary: glossary
        )
        #expect(!verdict.accepted)
        #expect(verdict.reasons.map(\.kind) == [.dropped])
    }

    @Test("Punctuation and capitalisation changes pass")
    func acceptsPunctuation() {
        let verdict = VocabularyGuard.check(
            original: "so right now its more or less exploration no practical coding",
            candidate: "So right now, its more or less exploration, no practical coding.",
            glossary: glossary
        )
        #expect(verdict.accepted)
    }
}

/// Refused corrections are logged, and log entries are public: the words of a
/// dictation may appear only when the user has asked for them.
struct RefusalLoggingTests {

    private let refusals = [
        Refusal(kind: .spelling, detail: "Kolyma → Cholera"),
        Refusal(kind: .spelling, detail: "Postgre → Poster"),
        Refusal(kind: .invented, detail: "invented “PostgreSQL”"),
    ]
    private let words = ["Kolyma", "Cholera", "Postgre", "Poster", "PostgreSQL"]

    @Test("Refusals are counted by kind")
    func summaryCountsByKind() {
        #expect(Refusal.summary(of: refusals) == "2 spelling suggestions, 1 invented word")
        #expect(Refusal.summary(of: [Refusal(kind: .dropped, detail: "dropped “Docker”")])
            == "1 dropped glossary term")
    }

    @Test("By default the log holds the counts and none of the dictated words")
    func logHoldsNoWordsByDefault() {
        let lines = Refusal.logLines(for: refusals, mode: "spelling", includingWords: false)

        #expect(lines == ["cleanup[spelling] refused 2 spelling suggestions, 1 invented word"])
        for word in words {
            #expect(!lines.joined().contains(word), "\(word) reached the log")
        }
    }

    @Test("With the comparison switched on the refused words are logged too")
    func logHoldsWordsWhenAsked() throws {
        let lines = Refusal.logLines(for: refusals, mode: "spelling", includingWords: true)

        try #require(lines.count == 2)
        for word in words {
            #expect(lines[1].contains(word), "\(word) is missing")
        }
    }

    @Test("Nothing refused, nothing logged")
    func nothingRefusedLogsNothing() {
        #expect(Refusal.logLines(for: [], mode: "spelling", includingWords: true).isEmpty)
    }
}

struct ModelOutputTests {

    @Test("The reply is read out of the corrected tags")
    func extractsTaggedReply() {
        #expect(ModelOutput.extract("<corrected>Hello there.</corrected>") == "Hello there.")
    }

    @Test("An unclosed tag is still parsed")
    func extractsUnclosedReply() {
        // Smaller models routinely open the tag and never close it. Without
        // this the literal "<corrected>" ends up injected into the user's text.
        #expect(ModelOutput.extract("<corrected>\nHello there.") == "Hello there.")
    }

    @Test("A reply with no tags at all is taken as-is")
    func extractsUntaggedReply() {
        #expect(ModelOutput.extract("  Hello there.  ") == "Hello there.")
    }

    @Test("Markdown emphasis the model invents is stripped")
    func stripsMarkdown() {
        // Observed in real dictation: "stop Ollama service" came back as
        // "stop **Ollama** service". The vocabulary guard cannot catch it,
        // because the word survives and only the punctuation around it is new.
        #expect(ModelOutput.normalise("stop **Ollama** service") == "stop Ollama service")
        #expect(ModelOutput.normalise("a *really* good idea") == "a really good idea")
    }

    @Test("Curly quotes are converted back to straight ones")
    func normalisesQuotes() {
        // gemma3:4b substitutes these unasked. Dictated text lands in editors
        // and terminals, where a curly apostrophe is a syntax error.
        #expect(ModelOutput.normalise("Let\u{2019}s go") == "Let's go")
        #expect(ModelOutput.normalise("\u{201C}quoted\u{201D}") == "\"quoted\"")
    }

    @Test("The glossary reaches the prompt")
    func includesGlossary() {
        let prompt = ModelOutput.prompt(for: "test", glossary: ["Colima", "Postgres"])
        #expect(prompt.contains("Colima, Postgres"))
        #expect(prompt.contains("<text>\ntest\n</text>"))
    }

    @Test("An accepted reply replaces the transcript")
    func resultAcceptsCorrection() throws {
        let result = try #require(ModelOutput.result(
            reply: "<corrected>Move it to Colima.</corrected>",
            original: "Move it to Kolyma.",
            glossary: ["Colima"],
            mode: .appleModel,
            started: Date()
        ))
        #expect(result.text == "Move it to Colima.")
        #expect(result.original == "Move it to Kolyma.")
        #expect(result.mode == .appleModel)
        #expect(result.rejected.isEmpty)
    }

    @Test("A translated reply is refused and the transcript kept")
    func resultRefusesTranslation() throws {
        // Observed from the Apple Intelligence model on macOS 27.0: asked to
        // correct a Russian transcript, it answered in English.
        let original = "Давай перенесем контейнер Postgres на Колема сегодня днем."
        let result = try #require(ModelOutput.result(
            reply: "<corrected>Let's move the container Postgres to Colima today.</corrected>",
            original: original,
            glossary: ["Colima", "Postgres"],
            mode: .appleModel,
            started: Date()
        ))
        #expect(result.text == original)
        #expect(!result.changed)
        #expect(!result.rejected.isEmpty)
    }

    @Test("An empty reply yields no result")
    func resultRejectsEmptyReply() {
        let result = ModelOutput.result(
            reply: "<corrected></corrected>",
            original: "Hello there.",
            glossary: [],
            mode: .model,
            started: Date()
        )
        #expect(result == nil)
    }
}
