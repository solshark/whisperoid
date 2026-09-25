import Testing

@testable import WhisperoidCore

struct TranscriberPromptTests {

    @Test("No glossary means no prompt")
    func emptyGlossary() {
        #expect(Transcriber.prompt(for: []) == nil)
        #expect(Transcriber.prompt(for: ["", "  "]) == nil)
    }

    @Test("A single term reads as a sentence")
    func singleTerm() {
        #expect(Transcriber.prompt(for: ["Colima"]) == "We use Colima.")
    }

    @Test("Terms are listed as punctuated prose")
    func severalTerms() {
        // The model copies the style of its prompt as well as the spelling of
        // its terms, so the prompt is written as a punctuated sentence.
        #expect(Transcriber.prompt(for: ["Claude Code", " Colima ", "", "Postgres"])
            == "We use Claude Code, Colima and Postgres.")
    }
}
