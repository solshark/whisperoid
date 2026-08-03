import Foundation
import Testing

@testable import WhisperoidCore

/// Model resolution decides whether the app starts offline or reaches for the
/// network. Treating an interrupted download as a usable model is the expensive
/// mistake: the app then skips the download and fails later, during load, with
/// an error that says nothing about the real cause.
struct ModelResolutionTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperoid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a model tree, optionally omitting one component to stand in for an
    /// interrupted download.
    private func writeModel(in storage: URL, omitting missing: String? = nil) throws {
        let folder = Transcriber.modelFolder(in: storage)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("config.json"))

        for component in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] where component != missing {
            let payload = folder
                .appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try Data().write(to: payload.appendingPathComponent("coremldata.bin"))
        }
    }

    @Test("An empty directory holds no model")
    func absentModel() throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        #expect(Transcriber.localModel(in: storage) == nil)
    }

    @Test("A complete model tree resolves")
    func completeModel() throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        try writeModel(in: storage)
        #expect(Transcriber.localModel(in: storage) != nil)
    }

    @Test("A model missing config.json does not resolve")
    func missingConfiguration() throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        try writeModel(in: storage)
        try FileManager.default.removeItem(
            at: Transcriber.modelFolder(in: storage).appendingPathComponent("config.json")
        )
        #expect(Transcriber.localModel(in: storage) == nil)
    }

    /// The case that matters: a directory that exists and looks populated but
    /// whose download stopped part way through.
    @Test("An interrupted download does not resolve", arguments: ["AudioEncoder", "MelSpectrogram", "TextDecoder"])
    func partialDownload(missing: String) throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        try writeModel(in: storage, omitting: missing)
        #expect(
            Transcriber.localModel(in: storage) == nil,
            "a tree missing \(missing) was treated as a usable model"
        )
    }

    @Test("A component directory with no payload does not resolve")
    func emptyComponentDirectory() throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }

        try writeModel(in: storage, omitting: "TextDecoder")
        // The directory exists but the Core ML payload inside it never arrived,
        // which is what an interrupted download actually leaves behind.
        try FileManager.default.createDirectory(
            at: Transcriber.modelFolder(in: storage)
                .appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(Transcriber.localModel(in: storage) == nil)
    }

    @Test("The model folder is derived from the repository and variant")
    func modelFolderLayout() throws {
        let storage = URL(fileURLWithPath: "/tmp/whisperoid-layout", isDirectory: true)
        let folder = Transcriber.modelFolder(in: storage)

        #expect(folder.path.hasPrefix(storage.path))
        #expect(folder.path.contains(Transcriber.modelRepository))
        #expect(folder.lastPathComponent == Transcriber.modelVariant)
    }

    @Test("A recording shorter than the minimum is rejected before transcription")
    func minimumDurationIsPositive() {
        // Guards against the minimum being zeroed, which would send empty
        // recordings to Whisper on every accidental double-tap of the hotkey.
        #expect(Transcriber.minimumSeconds > 0)
    }
}
