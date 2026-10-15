import Foundation
import Testing

@testable import WhisperoidCore

/// The setup window's progress bar is only as honest as these numbers. The
/// failure being guarded against is the one the app shipped with: progress that
/// sits still for most of the download because the file in flight is not where
/// anyone is looking.
struct ModelDownloadTests {

    // MARK: - Bytes on disk

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperoid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ byteCount: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: byteCount).write(to: url)
    }

    @Test("A file still in transit counts towards the download")
    func countsIncompleteFiles() throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        let finished = Transcriber.modelFolder(in: storage)
            .appendingPathComponent("config.json")
        try write(1_000, to: finished)

        // Where the downloader streams a file before moving it into place.
        let inFlight = storage
            .appendingPathComponent("models/\(Transcriber.modelRepository)/.cache/huggingface/download")
            .appendingPathComponent(Transcriber.modelVariant)
            .appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin.0123abcd.incomplete")
        try write(50_000, to: inFlight)

        #expect(Transcriber.downloadedBytes(in: storage) == 51_000)
    }

    @Test("Another variant's files do not count")
    func ignoresOtherVariants() throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        let repository = storage.appendingPathComponent("models/\(Transcriber.modelRepository)")
        try write(7_000, to: repository.appendingPathComponent("openai_whisper-tiny/config.json"))
        try write(9_000, to: repository
            .appendingPathComponent(".cache/huggingface/download/openai_whisper-tiny/x.incomplete"))

        #expect(Transcriber.downloadedBytes(in: storage) == 0)
    }

    // MARK: - Size from the model host

    @Test("The listing total sums files and skips directories")
    func sumsListing() throws {
        let listing = """
        [
          {"type": "directory", "oid": "a", "size": 0, "path": "v/AudioEncoder.mlmodelc"},
          {"type": "file", "oid": "b", "size": 243, "path": "v/config.json"},
          {"type": "file", "oid": "c", "size": 1300000000,
           "lfs": {"oid": "d", "size": 1300000000, "pointerSize": 134},
           "path": "v/AudioEncoder.mlmodelc/weights/weight.bin"}
        ]
        """
        #expect(try ModelCatalog.totalFileBytes(inTreeListing: Data(listing.utf8)) == 1_300_000_243)
    }

    @Test("A listing with no files is an error, not a zero-byte download")
    func rejectsEmptyListing() {
        let listing = #"[{"type": "directory", "oid": "a", "size": 0, "path": "v"}]"#
        #expect(throws: ModelCatalog.CatalogError.self) {
            try ModelCatalog.totalFileBytes(inTreeListing: Data(listing.utf8))
        }
    }

    @Test("The listing URL names the repository and the variant folder")
    func listingURL() throws {
        let url = try ModelCatalog.treeURL(
            repository: "argmaxinc/whisperkit-coreml",
            variant: "openai_whisper-large-v3-v20240930_turbo"
        )
        #expect(url.absoluteString == "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml"
            + "/tree/main/openai_whisper-large-v3-v20240930_turbo?recursive=true")
    }

    // MARK: - Rate and time remaining

    @Test("No rate until at least a second of history exists")
    func rateNeedsHistory() {
        var meter = DownloadMeter()
        #expect(meter.bytesPerSecond == nil)

        meter.record(bytes: 0, at: 100)
        meter.record(bytes: 5_000_000, at: 100.5)
        #expect(meter.bytesPerSecond == nil)

        meter.record(bytes: 10_000_000, at: 101)
        #expect(meter.bytesPerSecond == 10_000_000)
    }

    @Test("The rate follows a change of speed once the window has passed")
    func rateFollowsRecentSamples() throws {
        var meter = DownloadMeter(window: 5)
        var bytes: Int64 = 0
        // Ten seconds at 1 MB/s, then ten at 20 MB/s.
        for second in 0..<10 {
            meter.record(bytes: bytes, at: TimeInterval(second))
            bytes += 1_000_000
        }
        for second in 10...20 {
            meter.record(bytes: bytes, at: TimeInterval(second))
            bytes += 20_000_000
        }
        let rate = try #require(meter.bytesPerSecond)
        #expect(rate == 20_000_000)
    }

    @Test("Progress without a known total has no fraction and no estimate")
    func unknownTotal() {
        let progress = DownloadProgress(bytes: 400_000_000, bytesPerSecond: 20_000_000)
        #expect(progress.fraction == nil)
        #expect(progress.secondsRemaining == nil)
        #expect(progress.amountDescription.hasSuffix("so far"))
    }

    @Test("Fraction and time remaining come from the known total")
    func knownTotal() throws {
        let progress = DownloadProgress(
            bytes: 400_000_000,
            totalBytes: 1_600_000_000,
            bytesPerSecond: 20_000_000
        )
        #expect(progress.fraction == 0.25)
        #expect(progress.secondsRemaining == 60)
    }

    @Test("A total that is passed never reports more than complete")
    func fractionIsClamped() {
        let progress = DownloadProgress(bytes: 1_700_000_000, totalBytes: 1_600_000_000)
        #expect(progress.fraction == 1)
    }

    @Test("Time remaining is described in whole minutes")
    func remainingWording() {
        #expect(DownloadProgress.remainingDescription(seconds: 59) == "less than a minute left")
        #expect(DownloadProgress.remainingDescription(seconds: 60) == "about 1 min left")
        #expect(DownloadProgress.remainingDescription(seconds: 61) == "about 2 min left")
    }
}
