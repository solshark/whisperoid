import Testing

@testable import WhisperoidCore

/// Covers how the keep-alive finds a headset's output. Playing to one needs
/// the headset, so that part is checked on the device and in the system log.
struct HeadsetKeepAliveTests {

    @Test("A Bluetooth headset's input maps to the output at the same address")
    func headsetInputMapsToOutput() {
        #expect(HeadsetKeepAlive.outputUID(forInputUID: "0A-1B-2C-3D-4E-5F:input") == "0A-1B-2C-3D-4E-5F:output")
    }

    @Test("Inputs that are not one half of a headset map to nothing", arguments: [
        "BuiltInMicrophoneDevice",
        "AppleUSBAudioEngine:Unknown Manufacturer:USB Camera:00000000:3",
        ":input",
        "0A-1B-2C-3D-4E-5F:output",
        "",
    ])
    func otherInputsMapToNothing(uid: String) {
        #expect(HeadsetKeepAlive.outputUID(forInputUID: uid) == nil)
    }

    @Test("An output that does not exist is not found")
    func missingOutputIsNotFound() {
        #expect(HeadsetKeepAlive.outputDevice(uid: "00-00-00-00-00-00:output") == nil)
    }

    @Test("A keep-alive is not started for a headset that is not there")
    func missingHeadsetThrows() {
        #expect(throws: HeadsetKeepAlive.KeepAliveError.self) {
            try HeadsetKeepAlive(inputUID: "00-00-00-00-00-00:input")
        }
    }

    @Test("A keep-alive is not started for an input that is not a headset")
    func nonHeadsetThrows() {
        #expect(throws: HeadsetKeepAlive.KeepAliveError.self) {
            try HeadsetKeepAlive(inputUID: "BuiltInMicrophoneDevice")
        }
    }

    /// The positive control for the cases above, which would all pass if
    /// nothing could ever be found or started. Uses the built-in speaker rather
    /// than whatever the default output is: starting and stopping an output on
    /// a Bluetooth headset someone is dictating through is the very event the
    /// keep-alive exists to survive. Zeros, so nothing is heard.
    @Test(
        "Silence plays to a real output device and stops when asked",
        .enabled(if: HeadsetKeepAlive.outputDevice(uid: "BuiltInSpeakerDevice") != nil)
    )
    func playsToRealOutput() async throws {
        let keepAlive = try HeadsetKeepAlive(outputUID: "BuiltInSpeakerDevice")
        try await Task.sleep(for: .milliseconds(300))

        let report = try #require(keepAlive.stop())
        #expect(report.contains("first after"))
        let cycles = try #require(Int(report.prefix { $0.isNumber }))
        #expect(cycles > 0)

        #expect(keepAlive.stop() == nil)
    }
}
