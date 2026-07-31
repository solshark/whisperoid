import Foundation

/// Every file the app owns lives under a single configurable root. Keeping path
/// resolution in one place means a future move into a sandbox container is a
/// change here rather than a change everywhere.
public enum Paths {

    /// `WHISPEROID_SUPPORT_DIR` relocates everything the app stores, which
    /// allows a first-run download to be exercised without disturbing the
    /// existing model cache.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WHISPEROID_SUPPORT_DIR"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Whisperoid", isDirectory: true)
    }

    @discardableResult
    public static func ensureSupportDirectory() throws -> URL {
        let url = supportDirectory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
