import Foundation

/// How far the model download has got, measured in bytes.
///
/// WhisperKit reports progress in files: each of the model's two dozen files
/// counts for the same share regardless of its size, so the audio encoder,
/// which holds 1.3 GB of a 1.6 GB download, moves the figure by about four
/// percent. Bytes on disk, measured against the size the model host reports,
/// is what a progress bar can honestly show.
public struct DownloadProgress: Sendable, Equatable {

    /// Bytes on disk so far, including files still in transit.
    public var bytes: Int64
    /// Size of the whole download, when the model host could be asked for it.
    public var totalBytes: Int64?
    /// Recent transfer rate; nil until there is enough history to measure it.
    public var bytesPerSecond: Double?

    public init(bytes: Int64 = 0, totalBytes: Int64? = nil, bytesPerSecond: Double? = nil) {
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }

    public var secondsRemaining: Double? {
        guard let totalBytes, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return max(0, Double(totalBytes - bytes) / bytesPerSecond)
    }

    /// "412 MB of 1.64 GB", or "412 MB so far" when the total is unknown.
    public var amountDescription: String {
        let done = Self.format(bytes)
        guard let totalBytes else { return "\(done) so far" }
        return "\(done) of \(Self.format(totalBytes))"
    }

    /// "23.4 MB/s · about 2 min left", or as much of that as is known.
    public var rateDescription: String? {
        var parts: [String] = []
        if let bytesPerSecond {
            parts.append("\(Self.format(Int64(bytesPerSecond)))/s")
        }
        if let secondsRemaining {
            parts.append(Self.remainingDescription(seconds: secondsRemaining))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whole minutes only. A seconds countdown driven by a network transfer
    /// jumps around constantly and reads as less trustworthy than a coarse
    /// figure that holds still.
    static func remainingDescription(seconds: Double) -> String {
        seconds < 60
            ? "less than a minute left"
            : "about \(Int((seconds / 60).rounded(.up))) min left"
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

/// Transfer rate over a sliding window.
///
/// Measured from successive byte counts rather than taken from the downloader,
/// so it covers the whole download and not only the file currently in flight.
/// A window of several seconds smooths over the bursts of a network transfer
/// without lagging far behind a genuine change of speed.
public struct DownloadMeter: Sendable {

    private struct Sample: Sendable {
        let time: TimeInterval
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private let window: TimeInterval

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// `time` must come from a monotonic clock, such as
    /// `ProcessInfo.systemUptime`; wall-clock time can step backwards.
    public mutating func record(bytes: Int64, at time: TimeInterval) {
        samples.append(Sample(time: time, bytes: bytes))
        // Keep the newest sample that is older than the window as the
        // baseline, so the measured span stays close to the full window rather
        // than shrinking to whatever happens to be inside it.
        while samples.count > 2, samples[1].time <= time - window {
            samples.removeFirst()
        }
    }

    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= 1 else { return nil }
        // A file moving out of the download cache can briefly be missed by a
        // directory walk, which would otherwise read as negative speed.
        return max(0, Double(last.bytes - first.bytes) / span)
    }
}

/// What the model host says about a model before any of it is downloaded.
public enum ModelCatalog {

    public enum CatalogError: LocalizedError {
        case invalidURL
        case badResponse(Int)
        case paginated
        case empty

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Could not build the model listing URL."
            case .badResponse(let status): "The model listing returned HTTP \(status)."
            case .paginated: "The model listing is split across pages."
            case .empty: "The model listing contains no files."
            }
        }
    }

    /// Total size of a model variant, from one request to Hugging Face's tree
    /// API.
    ///
    /// Used only to show the size of the download and how far it has got. A
    /// failure here costs the progress bar its total and nothing else, so
    /// callers are expected to carry on without it.
    ///
    /// Checked on 2026-10-15: the listing for the default variant sums to
    /// 1,638,464,446 bytes across 24 files, exactly what a completed download
    /// occupies on disk.
    public static func downloadSize(
        repository: String,
        variant: String,
        session: URLSession = .shared
    ) async throws -> Int64 {
        let request = URLRequest(url: try treeURL(repository: repository, variant: variant),
                                 timeoutInterval: 15)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // Following further pages is not worth the code for a listing of a few
        // dozen entries. Summing only the first page would understate the total
        // and finish the progress bar early, so a paginated answer is treated
        // as no answer.
        guard http.value(forHTTPHeaderField: "Link") == nil else {
            throw CatalogError.paginated
        }
        return try totalFileBytes(inTreeListing: data)
    }

    static func treeURL(repository: String, variant: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repository)/tree/main/\(variant)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = components.url else { throw CatalogError.invalidURL }
        return url
    }

    static func totalFileBytes(inTreeListing data: Data) throws -> Int64 {
        struct Entry: Decodable {
            struct LargeFile: Decodable {
                let size: Int64
            }
            let type: String
            let size: Int64?
            let lfs: LargeFile?
        }

        let total = try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" }
            // For files stored in LFS the top-level size has been the real
            // size too, but the LFS record is the one documented as such.
            .reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size ?? 0) }

        guard total > 0 else { throw CatalogError.empty }
        return total
    }
}
