import CoreAudio
import Foundation

/// Plays digital silence to a Bluetooth headset for as long as its microphone
/// is being recorded.
///
/// AirPods Max can bring up their voice link and then send nothing over it.
/// On 2026-10-22 bluetoothd counted zero received voice packets a second for
/// the whole of every failed recording, on a link macOS reported as connected,
/// and Whisperoid received a correctly formatted stream of bit-exact zeros.
/// Reopening the input never revived one, and the state outlived the
/// recording: up to six attempts in a row failed the same way.
///
/// Each of that day's five such runs began after another application's output
/// to the headset ended while a voice link was up: a system sound, a paused
/// video in Safari, a Teams call. In most of them macOS's Bluetooth audio
/// driver went on reporting an output session that no longer existed. The
/// cause inside macOS is not known. What was consistent is the other side:
/// each of the four recordings that started while some application's output
/// was running on the headset worked, one of them in that state, where voice
/// packets arrived within a second of a system sound starting 0.8 s in.
///
/// So while recording from a Bluetooth headset, Whisperoid keeps an output of
/// its own running on it, carrying nothing but zeros. It is started after the
/// input and stopped after it, because an output ending while the input is
/// still running is the event that preceded every failure.
///
/// Every call here goes to the audio hardware and can block, so the owner runs
/// them where a hang is survivable: on `AudioRecorder`'s audio queue.
final class HeadsetKeepAlive: @unchecked Sendable {

    enum KeepAliveError: LocalizedError {
        case noOutput(String)
        case failed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutput(let uid):
                "no output device matches \(uid)"
            case .failed(let operation, let status):
                "\(operation) failed with OSStatus \(status)"
            }
        }
    }

    /// Written only by the IO thread while the output runs, and read only once
    /// it has been stopped and its IOProc destroyed, after which CoreAudio no
    /// longer calls it. That ordering is what makes this safe without a lock,
    /// which a real-time thread should not take.
    private final class Cycles: @unchecked Sendable {
        var count = 0
        var firstUptime: UInt64?
    }

    let outputUID: String
    private let deviceID: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    private let cycles = Cycles()
    private var startUptime: UInt64 = 0

    /// The output half of a Bluetooth headset whose input has `inputUID`.
    ///
    /// macOS presents a headset as two devices sharing one address, the
    /// microphone as `<address>:input` and the speaker as `<address>:output`.
    static func outputUID(forInputUID inputUID: String) -> String? {
        let suffix = ":input"
        guard inputUID.hasSuffix(suffix), inputUID.count > suffix.count else { return nil }
        return String(inputUID.dropLast(suffix.count)) + ":output"
    }

    /// The device with this unique ID, provided it has an output stream.
    static func outputDevice(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifierPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streams, 0, nil, &streamsSize) == noErr,
              streamsSize > 0
        else { return nil }

        return deviceID
    }

    /// Finds the headset's output and starts playing silence to it.
    convenience init(inputUID: String) throws {
        guard let uid = Self.outputUID(forInputUID: inputUID) else {
            throw KeepAliveError.noOutput(inputUID)
        }
        try self.init(outputUID: uid)
    }

    /// Starts playing silence to the output device with this unique ID.
    init(outputUID uid: String) throws {
        guard let deviceID = Self.outputDevice(uid: uid) else {
            throw KeepAliveError.noOutput(uid)
        }
        self.outputUID = uid
        self.deviceID = deviceID

        let cycles = self.cycles
        var procID: AudioDeviceIOProcID?
        // No dispatch queue: the block runs on CoreAudio's IO thread, where
        // filling a buffer with zeros belongs.
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            if cycles.firstUptime == nil {
                cycles.firstUptime = DispatchTime.now().uptimeNanoseconds
            }
            cycles.count += 1
        }
        guard created == noErr, let procID else {
            throw KeepAliveError.failed("creating the output IOProc", created)
        }

        startUptime = DispatchTime.now().uptimeNanoseconds
        let started = AudioDeviceStart(deviceID, procID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            throw KeepAliveError.failed("starting the output", started)
        }
        self.procID = procID
    }

    deinit {
        _ = stop()
    }

    /// Stops the output, once. Returns a one-line account of how it ran, or
    /// nil if it had already been stopped.
    @discardableResult
    func stop() -> String? {
        guard let procID else { return nil }
        self.procID = nil
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)

        let first = cycles.firstUptime.map { uptime in
            String(format: "first after %.3f s", Double(uptime &- startUptime) / 1_000_000_000)
        } ?? "never called"
        return "\(cycles.count) output cycles to \(outputUID), \(first)"
    }
}
