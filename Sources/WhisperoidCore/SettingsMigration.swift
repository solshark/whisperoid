import Foundation

/// Carries settings over from Whisperoid's previous bundle ID.
///
/// Whisperoid was `com.solshark.whisperoid` until its signing moved to Black
/// Meridian's team, and is `online.blackmeridian.whisperoid` since. macOS keeps
/// preferences per bundle ID, so without this the shortcut, the glossary and
/// every other setting would silently return to their defaults.
///
/// A sandboxed build cannot read another application's preferences, so there
/// it finds nothing to import, which is right: nobody used the sandboxed build
/// under the old ID.
public enum SettingsMigration {

    public static let previousDomain = "com.solshark.whisperoid"

    /// Recorded once the import has run, so that it runs once: a setting the
    /// user removes later must not come back from the old domain.
    static let doneKey = "settingsImportedFromPreviousBundleID"

    /// Copies each setting stored under the previous bundle ID that `domain`
    /// does not already hold, the first time it is called. Returns how many
    /// were copied.
    ///
    /// - Parameters:
    ///   - defaults: where settings are written; `UserDefaults.standard` in the app.
    ///   - domain: the domain `defaults` writes to, the app's bundle ID. Only
    ///     settings actually stored there count as already present, not
    ///     registered defaults.
    ///   - previous: the settings stored under the previous bundle ID.
    @discardableResult
    public static func importPreviousSettings(
        into defaults: UserDefaults,
        domain: String,
        previous: [String: Any]?
    ) -> Int {
        guard domain != previousDomain, !defaults.bool(forKey: doneKey) else { return 0 }
        defer { defaults.set(true, forKey: doneKey) }

        let current = defaults.persistentDomain(forName: domain) ?? [:]
        var copied = 0
        for (key, value) in previous ?? [:] where current[key] == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// The app's own call: from the previous bundle ID into this one.
    @discardableResult
    public static func importPreviousSettings() -> Int {
        guard let domain = Bundle.main.bundleIdentifier else { return 0 }
        return importPreviousSettings(
            into: .standard,
            domain: domain,
            previous: UserDefaults.standard.persistentDomain(forName: previousDomain)
        )
    }
}
