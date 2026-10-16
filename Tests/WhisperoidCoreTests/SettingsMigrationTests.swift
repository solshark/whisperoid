import Foundation
import Testing

@testable import WhisperoidCore

/// The move to a new bundle ID must not cost the existing users their
/// shortcut, glossary or other settings, and must not undo later changes.
struct SettingsMigrationTests {

    /// A preferences domain of its own for each test, removed afterwards.
    private func withDomain(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let domain = "SettingsMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, domain)
    }

    private let previous: [String: Any] = [
        "hotkey.toggleDictation": Data([1, 2, 3]),
        "cleanupGlossary": "Colima\nWhisperKit",
        "silenceSeconds": 2.0,
        "playSounds": false,
    ]

    @Test("Every previous setting is copied on the first launch")
    func copiesEverything() {
        withDomain { defaults, domain in
            let copied = SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: previous)

            #expect(copied == 4)
            #expect(defaults.data(forKey: "hotkey.toggleDictation") == Data([1, 2, 3]))
            #expect(defaults.string(forKey: "cleanupGlossary") == "Colima\nWhisperKit")
            #expect(defaults.double(forKey: "silenceSeconds") == 2.0)
            #expect(defaults.object(forKey: "playSounds") as? Bool == false)
        }
    }

    @Test("A setting already made under the new bundle ID is kept")
    func keepsNewerSettings() {
        withDomain { defaults, domain in
            defaults.set(3.5, forKey: "silenceSeconds")

            SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: previous)

            #expect(defaults.double(forKey: "silenceSeconds") == 3.5)
            #expect(defaults.string(forKey: "cleanupGlossary") == "Colima\nWhisperKit")
        }
    }

    @Test("A registered default does not count as a setting the user made")
    func overridesRegisteredDefaults() {
        withDomain { defaults, domain in
            defaults.register(defaults: ["silenceSeconds": 4.0])

            SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: previous)

            #expect(defaults.double(forKey: "silenceSeconds") == 2.0)
        }
    }

    @Test("It runs once, so a setting removed later does not come back")
    func runsOnce() {
        withDomain { defaults, domain in
            SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: previous)
            defaults.removeObject(forKey: "cleanupGlossary")

            let copied = SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: previous)

            #expect(copied == 0)
            #expect(defaults.object(forKey: "cleanupGlossary") == nil)
        }
    }

    @Test("Nothing to import is not an error, and still counts as done")
    func nothingPrevious() {
        withDomain { defaults, domain in
            #expect(SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: nil) == 0)
            #expect(SettingsMigration.importPreviousSettings(into: defaults, domain: domain, previous: previous) == 0)
        }
    }

    @Test("A build still using the previous bundle ID imports nothing from itself")
    func skipsSameDomain() {
        withDomain { defaults, _ in
            // A key no real preferences domain holds: the previous domain may
            // exist on the machine running the tests, and must not decide the
            // outcome.
            let key = "SettingsMigrationTests-\(UUID().uuidString)"

            let copied = SettingsMigration.importPreviousSettings(
                into: defaults, domain: SettingsMigration.previousDomain, previous: [key: true])

            #expect(copied == 0)
            #expect(defaults.object(forKey: key) == nil)
        }
    }
}
