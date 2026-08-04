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
        let prompt = EmbeddedCleaner.prompt(for: "test", glossary: ["Colima", "Postgres"])
        #expect(prompt.contains("Colima, Postgres"))
        #expect(prompt.contains("<text>\ntest\n</text>"))
    }
}
