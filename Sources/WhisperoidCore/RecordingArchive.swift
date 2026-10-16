import AVFoundation
import Foundation

/// Keeps recordings on disk, for a build made to debug transcription.
///
/// Nothing in a normal build calls this. The application does so only when
/// compiled with `KEEP_RECORDINGS`, which `scripts/build-app.sh` sets for
/// `WHISPEROID_KEEP_RECORDINGS=1`. Such a build keeps every dictation, as audio
/// and as transcribed, so that one which lost words can be replayed exactly
/// with `replaycheck`. It is for its developer's own machine and is never
/// distributed.
public enum RecordingArchive {

    public enum ArchiveError: LocalizedError {
        case emptyRecording
        case bufferUnavailable
        case unsupportedFormat(String)

        public var errorDescription: String? {
            switch self {
            case .emptyRecording: "there are no samples to write"
            case .bufferUnavailable: "could not allocate an audio buffer"
            case .unsupportedFormat(let path): "\(path) is not 16 kHz mono"
            }
        }
    }

    public static var directory: URL {
        Paths.supportDirectory.appendingPathComponent("recordings", isDirectory: true)
    }

    /// The name a recording's files share: the moment it stopped, which is the
    /// time on the log's `finishing with` line.
    public static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Writes 16 kHz mono samples as a 32-bit float WAV.
    ///
    /// Float rather than 16-bit because captured audio can exceed full scale —
    /// a headset has logged peaks of +2.9 dBFS — and clipping those would
    /// change exactly what the levelling measures. The file holds what the
    /// transcriber was given, bit for bit.
    @discardableResult
    public static func saveAudio(_ samples: [Float], named name: String, in directory: URL = directory) throws -> URL {
        guard !samples.isEmpty else { throw ArchiveError.emptyRecording }
        guard let format = AudioRecorder.makeTargetFormat(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw ArchiveError.bufferUnavailable }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return url
    }

    /// Reads a 16 kHz mono file back as samples.
    ///
    /// In a loop: a single `read(into:)` of a float WAV stopped 640 frames
    /// short of a one-second file and reported no error. Int16 files happened
    /// to read whole, which is how it went unnoticed.
    public static func loadAudio(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == AudioRecorder.targetSampleRate, format.channelCount == 1 else {
            throw ArchiveError.unsupportedFormat(url.path)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw ArchiveError.bufferUnavailable
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return samples
    }

    /// Writes the transcript beside the audio, so what was said can be
    /// compared with what came out.
    @discardableResult
    public static func saveText(_ text: String, named name: String, in directory: URL = directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
