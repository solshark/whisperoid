import AVFoundation
import Foundation
import WhisperoidCore

/// Replays a recording through the same RMS calculation the recorder uses and
/// the real `SilenceDetector`, reporting the level timeline, the adaptive
/// threshold, and the point at which auto-stop would fire.
///
/// Usage: vadcheck <file> [silenceSeconds] [dropDecibels]
@main
struct VADCheck {

    /// The recorder taps 4096 frames at the input rate, which is 48 kHz on this
    /// hardware; after conversion to 16 kHz that is roughly 1365 samples, or
    /// about 85 ms per level reading.
    static let frameSize = 1_365

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let path = args.first else {
            FileHandle.standardError.write(
                Data("usage: vadcheck <file> [silenceSeconds] [dropDecibels]\n".utf8)
            )
            exit(2)
        }

        let silenceSeconds = args.count > 1 ? Double(args[1]) ?? 3.0 : 3.0
        let drop = args.count > 2
            ? Float(args[2]) ?? SilenceDetector.defaultDropDecibels
            : SilenceDetector.defaultDropDecibels

        let samples = try loadSamples(at: path)
        let sampleRate = AudioRecorder.targetSampleRate
        let secondsPerFrame = Double(frameSize) / sampleRate

        print("file: \(URL(fileURLWithPath: path).lastPathComponent)")
        print(String(format: "duration: %.2f s", Double(samples.count) / sampleRate))
        print(String(format: "settings: drop %.0f dB below peak, silence %.1f s", drop, silenceSeconds))
        print(String(format: "level reading every %.0f ms\n", secondsPerFrame * 1_000))

        let detector = SilenceDetector(dropDecibels: drop, requiredSilence: silenceSeconds)
        let origin = Date(timeIntervalSince1970: 0)

        var firedAt: Double?
        var readings: [Reading] = []

        var index = 0
        var frame = 0
        while index + frameSize <= samples.count {
            let chunk = samples[index..<(index + frameSize)]
            let rms = Self.rms(of: chunk)
            let decibels = SilenceDetector.decibels(from: rms)
            let time = Double(frame) * secondsPerFrame

            let stop = detector.update(level: rms, now: origin.addingTimeInterval(time))
            if stop, firedAt == nil { firedAt = time }

            readings.append(
                Reading(time: time, decibels: decibels, threshold: detector.currentThreshold)
            )

            index += frameSize
            frame += 1
        }

        printTimeline(readings, firedAt: firedAt)

        let judged = readings.filter { $0.threshold != nil }
        let quiet = judged.filter { $0.decibels < ($0.threshold ?? 0) }

        print()
        print(String(format: "observed speech peak: %.1f dBFS", detector.observedPeak))
        if let threshold = detector.currentThreshold {
            print(String(format: "final threshold:      %.1f dBFS", threshold))
        } else {
            print("final threshold:      not armed (no speech detected)")
        }
        print(String(format: "readings below threshold: %d of %d (%.0f%%)",
                     quiet.count, judged.count,
                     100 * Double(quiet.count) / Double(max(judged.count, 1))))
        print(String(format: "longest continuous silence: %.2f s",
                     longestSilence(readings, step: secondsPerFrame)))

        if let firedAt {
            print(String(format: "AUTO-STOP would fire at %.2f s", firedAt))
        } else {
            print("auto-stop would not fire")
        }
    }

    private struct Reading {
        let time: Double
        let decibels: Float
        let threshold: Float?

        var isSilent: Bool {
            guard let threshold else { return false }
            return decibels < threshold
        }
    }

    // MARK: - Reporting

    private static func printTimeline(_ readings: [Reading], firedAt: Double?) {
        // One row per half second, showing the loudest reading in that window.
        let bucketSeconds = 0.5
        var peaks: [Int: Float] = [:]
        var silentAll: [Int: Bool] = [:]

        for reading in readings {
            let bucket = Int(reading.time / bucketSeconds)
            peaks[bucket] = max(peaks[bucket] ?? -.infinity, reading.decibels)
            silentAll[bucket] = (silentAll[bucket] ?? true) && reading.isSilent
        }

        for bucket in peaks.keys.sorted() {
            let peak = peaks[bucket] ?? -.infinity
            let time = Double(bucket) * bucketSeconds
            let clamped = max(-70, min(0, peak))
            let width = max(Int((clamped + 70) / 70 * 40), 0)
            let bar = String(repeating: "#", count: width)
            let mark = (silentAll[bucket] ?? false) ? "  <- silent" : ""
            let fired = firedAt.map { $0 >= time && $0 < time + bucketSeconds } ?? false
            print(String(format: "%5.1fs %6.1f dB %-40@%@%@",
                         time, peak, bar as NSString, mark, fired ? "  *** STOP ***" : ""))
        }
    }

    private static func longestSilence(_ readings: [Reading], step: Double) -> Double {
        var longest = 0.0
        var current = 0.0
        for reading in readings {
            if reading.isSilent {
                current += step
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    // MARK: - Audio

    private static func rms(of chunk: ArraySlice<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        return (sum / Float(chunk.count)).squareRoot()
    }

    private static func loadSamples(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "vadcheck", code: 1)
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw NSError(domain: "vadcheck", code: 2)
        }

        let capacity = AVAudioFrameCount(
            Double(file.length) * format.sampleRate / file.processingFormat.sampleRate
        ) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(domain: "vadcheck", code: 3)
        }

        let source = file
        nonisolated(unsafe) var finished = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if finished {
                status.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: AVAudioFrameCount(source.length)
            ) else {
                status.pointee = .endOfStream
                return nil
            }
            try? source.read(into: input)
            finished = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }

        guard let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
