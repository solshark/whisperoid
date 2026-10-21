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

/// The cleanup model is loaded again after every idle unload. A complete copy
/// on disk must be used as it is, or each load asks Hugging Face about every
/// file while the Mac is online.
struct CleanupModelResolutionTests {

    /// Not a repository on Hugging Face, so a download attempt fails rather
    /// than fetching anything.
    private let repository = "whisperoid-tests/not-a-repository"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperoid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a model folder, optionally omitting one file to stand in for an
    /// interrupted download. With `shards`, the weights are split and named by
    /// an index, as larger models are.
    private func writeModel(in folder: URL, shards: [String]? = nil, omitting missing: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files = ["config.json", "tokenizer.json", "tokenizer_config.json"]
        if let shards {
            let index = ["weight_map": Dictionary(uniqueKeysWithValues: shards.enumerated().map { ("layer.\($0.offset)", $0.element) })]
            try JSONSerialization.data(withJSONObject: index)
                .write(to: folder.appendingPathComponent("model.safetensors.index.json"))
            files += shards
        } else {
            files.append("model.safetensors")
        }
        for file in files where file != missing {
            try Data().write(to: folder.appendingPathComponent(file))
        }
    }

    @Test("A complete copy resolves")
    func completeCopy() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeModel(in: folder)
        #expect(HubModelDownloader.completeCopy(at: folder) == folder)
    }

    @Test("A copy missing a file it needs does not resolve",
          arguments: ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"])
    func partialCopy(missing: String) throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeModel(in: folder, omitting: missing)
        #expect(HubModelDownloader.completeCopy(at: folder) == nil,
                "a copy missing \(missing) was treated as complete")
    }

    @Test("Every weight file the index names must be present")
    func shardedCopy() throws {
        let complete = try temporaryDirectory(), partial = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: complete)
            try? FileManager.default.removeItem(at: partial)
        }
        let shards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]

        try writeModel(in: complete, shards: shards)
        try writeModel(in: partial, shards: shards, omitting: shards[1])
        #expect(HubModelDownloader.completeCopy(at: complete) == complete)
        #expect(HubModelDownloader.completeCopy(at: partial) == nil)
    }

    @Test("The folder is where the Hugging Face client puts the repository")
    func folderLayout() {
        let storage = URL(fileURLWithPath: "/tmp/whisperoid-layout", isDirectory: true)
        let folder = HubModelDownloader(storageDirectory: storage).localFolder(for: repository)

        #expect(folder.path == storage.path + "/models/" + repository)
    }

    @Test("A complete copy is loaded without asking the model host")
    func completeCopyNeedsNoNetwork() async throws {
        let storage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let downloader = HubModelDownloader(storageDirectory: storage)
        try writeModel(in: downloader.localFolder(for: repository))

        let folder = try await downloader.download(
            id: repository, revision: nil, matching: ["*.json", "*.safetensors"],
            useLatest: false, progressHandler: { _ in }
        )
        #expect(folder == downloader.localFolder(for: repository))
    }
}
