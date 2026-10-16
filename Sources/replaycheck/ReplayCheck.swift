import AVFoundation
import Foundation
import WhisperKit
@testable import WhisperoidCore

/// Development tool: replays recordings through the app's transcription path
/// under controlled variations, and scores word recall against a reference.
///
///     replaycheck --clips a.wav,b.wav [--pause 1.5] [--reference ref.txt]
///                 [--glossary terms.txt] [--gains -16,0,24 | --levels -45,-33]
///                 [--variants app,default-vad] [--repeat 1] [--dump app@0]
///
/// Clips must be 16 kHz mono. They are joined with pauses of room noise
/// matched to the quietest stretch of the first clip, so a long dictation can
/// be built from short real recordings, then scaled by each gain (in dB) or to
/// each target RMS level (in dBFS).
///
/// Variants:
/// - `app`: the app's path: levelled input and a pause threshold set from the
///   recording itself.
/// - `default-vad`: as 0.7.0 shipped it: unlevelled input and WhisperKit's
///   fixed pause threshold.
///
/// Either can carry modifiers, joined with `+`: `no-prompt` (no glossary
/// prompt), `no-skip` (no skipping of windows judged silent), `timestamps`
/// (decode with timestamps), `fixed` (fixed 30-second windows, no chunking).
@main
struct ReplayCheck {

    static func main() async throws {
        let args = Arguments(CommandLine.arguments.dropFirst())
        let clips = try args.list("--clips").map(loadClip)
        guard !clips.isEmpty else {
            print("usage: replaycheck --clips a.wav,b.wav [options]; see ReplayCheck.swift")
            return
        }
        let pause = Double(args.value("--pause") ?? "1.5") ?? 1.5
        let reference = try args.value("--reference").map { try String(contentsOfFile: $0, encoding: .utf8) }
        let glossary = try args.value("--glossary").map {
            try String(contentsOfFile: $0, encoding: .utf8)
                .split(whereSeparator: \.isNewline).map(String.init)
        } ?? []
        let gains = args.list("--gains").compactMap(Float.init).nilIfEmpty ?? [0]
        let levels = args.list("--levels").compactMap(Float.init)
        let variants = args.list("--variants").nilIfEmpty ?? ["app"]
        let repeats = Int(args.value("--repeat") ?? "1") ?? 1
        let dump = Set(args.list("--dump"))

        let audio = compose(clips, pause: pause)
        let audioLevel = decibels(rms(audio))
        print(String(format: "audio: %.1f s from %d clips, rms %.1f dBFS",
                     Double(audio.count) / 16000, clips.count, audioLevel))

        let storage = Paths.supportDirectory
        let pipe = try await WhisperKit(WhisperKitConfig(
            model: Transcriber.modelVariant,
            modelFolder: Transcriber.modelFolder(in: storage).path,
            tokenizerFolder: storage,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        ))

        let steps = levels.isEmpty ? gains : levels.map { $0 - audioLevel }
        print("variant              gain  recall  chars  chunks  empty  input dBFS  seconds")
        for gain in steps {
            let scaled = audio.map { $0 * pow(10, gain / 20) }
            for variant in variants {
                for run in 0..<repeats {
                    let input: [Float]
                    if variant.hasPrefix("default-vad") {
                        input = scaled.map { max(-1, min(1, $0)) }
                        pipe.voiceActivityDetector = nil
                    } else {
                        input = Transcriber.levelled(scaled).samples
                        pipe.voiceActivityDetector = EnergyVAD(
                            energyThreshold: Transcriber.pauseThreshold(for: input)
                        )
                    }

                    var options = Transcriber.decodingOptions()
                    if variant.contains("no-skip") { options.noSpeechThreshold = nil }
                    if variant.contains("timestamps") { options.withoutTimestamps = false }
                    if variant.contains("fixed") { options.chunkingStrategy = ChunkingStrategy.none }
                    if !variant.contains("no-prompt"), let prompt = Transcriber.prompt(for: glossary),
                       let tokenizer = pipe.tokenizer
                    {
                        let tokens = tokenizer.encode(text: " " + prompt)
                            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                        options.promptTokens = Array(tokens.prefix(Transcriber.maximumPromptTokens))
                    }

                    let started = Date()
                    let results = try await pipe.transcribe(audioArray: input, decodeOptions: options)
                    let seconds = Date().timeIntervalSince(started)

                    // Joined exactly as Transcriber.transcribe joins them.
                    let text = results.map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let empty = results.filter {
                        $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }.count
                    let recall = reference.map { String(format: "%.3f", wordRecall(text, reference: $0)) } ?? "  -  "
                    let label = (repeats > 1 ? "\(variant)#\(run + 1)" : variant)
                        .padding(toLength: 20, withPad: " ", startingAt: 0)
                    print(String(format: "%@ %+5.0f  %@  %5d  %6d  %5d  %10.1f  %7.2f",
                                 label as NSString, gain, recall as NSString, text.count,
                                 results.count, empty, decibels(rms(input)), seconds))

                    if dump.contains("\(variant)@\(Int(gain))") {
                        for (index, result) in results.enumerated() {
                            print("  chunk \(index): \(result.text.count) chars, lang \(result.language)")
                            for segment in result.segments {
                                print(String(format: "    %6.2f-%6.2f nospeech %.2f logprob %.2f temp %.1f  %@",
                                             segment.start, segment.end, segment.noSpeechProb,
                                             segment.avgLogprob, segment.temperature,
                                             String(segment.text.prefix(70)) as NSString))
                            }
                        }
                        print("  text: \(text)")
                    }
                }
            }
        }
    }

    // MARK: - Audio

    static func loadClip(_ path: String) throws -> [Float] {
        try RecordingArchive.loadAudio(from: URL(fileURLWithPath: path))
    }

    /// Joins clips with pauses of noise at the level of the first clip's
    /// quietest 100 ms, so a pause sounds like the room rather than like a
    /// device switching off.
    static func compose(_ clips: [[Float]], pause: Double) -> [Float] {
        let floor = Transcriber.frameLevels(clips[0]).map(\.rms).filter { $0 > 0 }.min() ?? 1e-4
        var generator = SplitMix(seed: 42)
        var audio: [Float] = []
        for (index, clip) in clips.enumerated() {
            if index > 0 {
                for _ in 0..<Int(pause * 16000) {
                    audio.append(floor * Float(generator.nextGaussian()))
                }
            }
            audio += clip
        }
        return audio
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func decibels(_ value: Float) -> Float { 20 * log10(max(value, 1e-9)) }

    // MARK: - Scoring

    /// Normalised so that how a number is written is not scored as a loss:
    /// "1, 2, 3", "12345" and "one, two, three" all become single digits.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .flatMap { word -> [String] in
                if let digit = numberWords[word] { return [digit] }
                if word.allSatisfy(\.isNumber) { return word.map { String($0) } }
                return [word]
            }
    }

    static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "один": "1", "два": "2", "три": "3", "четыре": "4", "пять": "5",
        "шесть": "6", "семь": "7", "восемь": "8", "девять": "9", "десять": "10",
    ]

    /// Longest common subsequence of words over the reference length: the
    /// share of the reference that survives, in order.
    static func wordRecall(_ text: String, reference: String) -> Double {
        let a = words(reference), b = words(text)
        guard !a.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for word in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, other) in b.enumerated() {
                current[j + 1] = word == other ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}

/// Deterministic noise, so a replay is repeatable.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextGaussian() -> Double {
        let u1 = max(Double(next() >> 11) / Double(1 << 53), 1e-12)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

struct Arguments {
    let values: [String]
    init(_ values: ArraySlice<String>) { self.values = Array(values) }
    func value(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name), index + 1 < values.count else { return nil }
        return values[index + 1]
    }
    func list(_ name: String) -> [String] {
        value(name)?.split(separator: ",").map(String.init) ?? []
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
