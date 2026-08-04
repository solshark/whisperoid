import Foundation
import WhisperoidCore

/// Development tool: runs the embedded cleanup model over the spike's ground
/// truth and reports what it fixed, missed and damaged.
///
/// Exists as an executable rather than a test because MLX resolves its Metal
/// shader library relative to the running binary, and the test runner does not
/// have it colocated. It also has to be built by `xcodebuild`: SwiftPM on the
/// command line cannot compile Metal shaders at all.
///
///     xcodebuild build -scheme cleanupcheck -destination 'platform=macOS' \
///         -derivedDataPath .build/xcode -configuration Release \
///         -skipPackagePluginValidation
///     .build/xcode/Build/Products/Release/cleanupcheck
@main
struct CleanupCheck {

    struct Case {
        let id: String
        let input: String
        /// Pairs of (the defect, what should replace it).
        let mustFix: [(String, String)]
        /// Words the speaker actually said, which must survive.
        let mustKeep: [String]
    }

    static let cases: [Case] = [
        Case(id: "en_real",
             input: "One, two, three, four, five. This is a blind test recording. Now I will see some keywords. For example, Postgre, Docker, Windows, Cloud Code.",
             mustFix: [("Postgre,", "Postgres"), ("Cloud Code", "Claude Code")],
             mustKeep: ["Docker", "Windows"]),
        Case(id: "ru_real",
             input: "1, 2, 3, 4, 5. Это слепой тест системы распознавания звука. Будет любопытно попробовать смешанный текст. Windows, Docker. Проверка.",
             mustFix: [],
             mustKeep: ["Windows", "Docker", "Проверка"]),
        Case(id: "en_tts",
             input: "Let's migrate the postgres container over to Kolyma this afternoon, then run the full test suite and check the parity manifest before we touch anything else.",
             mustFix: [("Kolyma", "Colima")],
             mustKeep: ["postgres", "parity manifest"]),
        Case(id: "ru_tts",
             input: "Давай перенесем контейнер Postgres на Колема сегодня днем, потом запустим полный набор тестов и проверим манифест перед тем, как трогать что-то еще.",
             mustFix: [("Колема", "Colima")],
             mustKeep: ["Postgres", "манифест"]),
        Case(id: "en_dictated",
             input: "So let's reframe it. Could we have a spike and try some models doing that post-processing instead of collecting transcripts? two weeks. And what about these Google Gemma models?",
             mustFix: [],
             mustKeep: ["spike", "post-processing", "Google Gemma"]),
    ]

    static func main() async {
        do {
            let directory = try Paths.ensureSupportDirectory()
            let cleaner = EmbeddedCleaner(storageDirectory: directory)

            let started = Date()
            try await cleaner.load { phase in
                if case .downloading = phase {
                    // Reported per file, and there are only a handful, so this
                    // is quiet enough to print unconditionally.
                    print("  \(phase.description)")
                } else {
                    print("  \(phase.description)")
                }
            }
            print(String(format: "load: %.1f s", Date().timeIntervalSince(started)))

            let configuration = EmbeddedCleaner.Configuration()
            var fixed = 0, defects = 0, damaged = 0
            var durations: [TimeInterval] = []

            for testCase in cases {
                let result = try await cleaner.clean(testCase.input, configuration: configuration)
                let got = result.text
                let corrected = testCase.mustFix.filter {
                    !got.contains($0.0) && got.contains($0.1)
                }
                let lost = testCase.mustKeep.filter {
                    got.range(of: $0, options: .caseInsensitive) == nil
                }

                fixed += corrected.count
                defects += testCase.mustFix.count
                damaged += lost.count
                durations.append(result.duration)

                let verdict = lost.isEmpty
                    ? (corrected.count == testCase.mustFix.count ? "ok" : "partial")
                    : "DAMAGE"
                print(String(format: "  [%@] %.2f s fixed=%d/%d damaged=%d %@",
                             testCase.id, result.duration, corrected.count,
                             testCase.mustFix.count, lost.count, verdict))
                if !lost.isEmpty { print("      LOST: \(lost)") }
                if !result.rejected.isEmpty { print("      REJECTED: \(result.rejected)") }
                if result.changed { print("      OUT: \(got)") }
            }

            let average = durations.reduce(0, +) / Double(max(durations.count, 1))
            print(String(format: "\n--> fixed %d/%d | damaged %d | avg %.2f s",
                         fixed, defects, damaged, average))

            await cleaner.unload()
            print("unloaded")
        } catch {
            FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
