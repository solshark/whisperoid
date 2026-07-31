import Foundation

/// Builds a self-contained report describing why startup might be stuck.
///
/// This exists because the failure modes that matter happen on machines with no
/// terminal to hand: a stalled download, a partially written model folder, a
/// full disk, or no route to the model host. Each of those looks identical from
/// the menu bar.
public enum Diagnostics {

    public static func report(
        storageDirectory: URL,
        status: String,
        lastError: String?,
        shortcut: String = "?"
    ) async -> String {
        var lines: [String] = []

        lines.append("Whisperoid diagnostics")
        lines.append(ISO8601DateFormatter().string(from: Date()))
        lines.append("")

        lines.append("## Application")
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("version:  \(version) (\(build))")
        lines.append("bundle:   \(bundle.bundlePath)")
        lines.append("status:   \(status)")
        lines.append("shortcut: \(shortcut)")
        lines.append("error:    \(lastError ?? "none")")
        lines.append("")

        lines.append("## System")
        let info = ProcessInfo.processInfo
        lines.append("macOS:    \(info.operatingSystemVersionString)")
        lines.append("cores:    \(info.processorCount)")
        lines.append("memory:   \(ByteCountFormatter.string(fromByteCount: Int64(info.physicalMemory), countStyle: .memory))")
        lines.append("arch:     \(machineArchitecture())")
        lines.append("")

        lines.append("## Storage")
        lines.append("support:  \(storageDirectory.path)")
        lines.append("exists:   \(FileManager.default.fileExists(atPath: storageDirectory.path))")
        lines.append("writable: \(FileManager.default.isWritableFile(atPath: storageDirectory.path))")
        lines.append("free:     \(freeSpaceDescription(at: storageDirectory))")
        lines.append("")

        lines.append("## Model")
        lines.append("variant:  \(Transcriber.modelVariant)")
        lines.append("repo:     \(Transcriber.modelRepository)")

        let modelFolder = Transcriber.modelFolder(in: storageDirectory)
        lines.append("folder:   \(modelFolder.path)")

        if FileManager.default.fileExists(atPath: modelFolder.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelFolder.path)) ?? []
            lines.append("contents: \(contents.count) entries")
            for entry in contents.sorted() {
                let size = directorySize(at: modelFolder.appendingPathComponent(entry))
                lines.append("  \(entry) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }
            let total = directorySize(at: modelFolder)
            lines.append("total:    \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
            lines.append("expected: about 1.6 GB complete, of which AudioEncoder.mlmodelc")
            lines.append("          alone is about 1.3 GB. Download progress is counted in")
            lines.append("          files, so it appears frozen for the whole of that one.")
        } else {
            lines.append("contents: folder does not exist yet")
        }
        lines.append("")

        lines.append("## Network")
        lines.append("Any HTTP status means the host answered and is reachable; a 403 from")
        lines.append("the CDN root is normal. Only FAILED indicates no route.")
        lines.append(await reachability())

        return lines.joined(separator: "\n")
    }

    // MARK: - Probes

    /// A short, explicitly bounded request. The point is to distinguish "no
    /// route to the host" from "the transfer is simply slow", so a hang here is
    /// itself the answer and must not be allowed to block indefinitely.
    private static func reachability() async -> String {
        let targets = [
            "https://huggingface.co",
            "https://cdn-lfs.hf.co",
        ]

        var results: [String] = []
        for target in targets {
            guard let url = URL(string: target) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(configuration: configuration)

            let started = Date()
            do {
                let (_, response) = try await session.data(for: request)
                let elapsed = Date().timeIntervalSince(started)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                results.append(String(format: "%@ — HTTP %d in %.2f s", target, code, elapsed))
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                results.append(String(format: "%@ — FAILED after %.2f s: %@",
                                      target, elapsed, error.localizedDescription))
            }
        }
        return results.joined(separator: "\n")
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    private static func freeSpaceDescription(at url: URL) -> String {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage {
                return ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            }
        } catch {
            return "unknown (\(error.localizedDescription))"
        }
        return "unknown"
    }

    /// Also used during startup to show that a large download is moving.
    public static func directorySize(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? Int64) ?? 0
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
