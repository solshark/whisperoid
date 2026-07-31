import Foundation
import os

/// Diagnostics.
///
/// These go to the unified log rather than stderr: an app bundle launched by
/// LaunchServices has no terminal attached, so stderr is discarded and the
/// messages are invisible exactly when they are most needed.
///
///     log stream --predicate 'subsystem == "com.solshark.whisperoid"'
///     log show --predicate 'subsystem == "com.solshark.whisperoid"' --last 5m
enum Log {

    private static let logger = Logger(subsystem: "com.solshark.whisperoid", category: "app")

    /// Uses `notice` rather than `info`: info-level entries are held in memory
    /// only and are routinely dropped before `log show` can retrieve them.
    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
