import AVFoundation
import Foundation
import Testing

@testable import WhisperoidCore

/// The archive exists so a failed transcription can be replayed exactly. These
/// check that what is read back is what was written, which is the whole point.
struct RecordingArchiveTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingArchiveTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Audio reads back bit for bit, including peaks above full scale")
    func audioRoundTrips() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var samples = (0..<16_000).map { 0.3 * sinf(2 * .pi * 440 * Float($0) / 16_000) }
        samples[100] = 1.4   // a +2.9 dBFS peak, as a headset has logged
        samples[200] = -1.4

        let url = try RecordingArchive.saveAudio(samples, named: "clip", in: directory)

        #expect(try RecordingArchive.loadAudio(from: url) == samples)
    }

    /// replaycheck reads its clips through this too, so a short read would
    /// make the replay tool itself lose the end of a recording.
    @Test("A recording longer than one read comes back whole")
    func longRecordingReadsWhole() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let samples = (0..<(92 * 16_000 + 123)).map { Float($0 % 1000) / 1000 - 0.5 }
        let url = try RecordingArchive.saveAudio(samples, named: "long", in: directory)

        #expect(try RecordingArchive.loadAudio(from: url) == samples)
    }

    @Test("An empty recording is refused rather than written as a broken file")
    func refusesEmpty() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: RecordingArchive.ArchiveError.self) {
            try RecordingArchive.saveAudio([], named: "empty", in: directory)
        }
    }

    @Test("The transcript is written beside the audio under the same name")
    func textBesideAudio() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = try RecordingArchive.saveAudio([0.1, 0.2], named: "same", in: directory)
        let text = try RecordingArchive.saveText("Это тест, and a test.", named: "same", in: directory)

        #expect(audio.deletingPathExtension() == text.deletingPathExtension())
        #expect(try String(contentsOf: text, encoding: .utf8) == "Это тест, and a test.")
    }

    @Test("Names use the stop time in 24-hour form")
    func namesUseStopTime() throws {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 10, 15)
        (components.hour, components.minute, components.second) = (15, 5, 5)
        let date = try #require(Calendar.current.date(from: components))

        #expect(RecordingArchive.baseName(for: date) == "2026-10-15_15-05-05")
    }
}
