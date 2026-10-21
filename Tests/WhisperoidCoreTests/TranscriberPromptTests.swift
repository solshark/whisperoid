import Testing
import WhisperKit

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

    @Test("Long recordings are split at pauses")
    func chunksAtPauses() {
        // Fixed 30-second windows lose speech at their boundaries, and with a
        // glossary prompt can lose whole windows. See decodingOptions().
        #expect(Transcriber.decodingOptions().chunkingStrategy == .vad)
    }

    @Test("A piece that starts mid-sentence is not abandoned")
    func firstTokenCheckOff() {
        // With the check, such a piece can fail at every temperature and come
        // back empty. See decodingOptions().
        #expect(Transcriber.decodingOptions().firstTokenLogProbThreshold == nil)
    }

    @Test("A piece the model stops early is resumed where it stopped")
    func decodesWithTimestamps() {
        // Only timestamps tell WhisperKit where the model stopped, so it can
        // decode the rest. See decodingOptions().
        #expect(Transcriber.decodingOptions().withoutTimestamps == false)
    }
}
