import Foundation

/// Recent observations, persisted so the burn-rate estimate and the last known values
/// survive a relaunch. Only the last 48 h are kept: the longest lookback is 6 h, and the
/// rest is just enough to show something sensible after a restart.
public final class SampleStore {
    public private(set) var samples: [Sample] = []
    private let url: URL?
    static let keep: TimeInterval = 48 * 3600

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            samples = (try? dec.decode([Sample].self, from: data)) ?? []
        }
    }

    public static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Burnbar", isDirectory: true).appendingPathComponent("samples.json")
    }

    public func append(_ u: Usage) {
        samples.append(Sample(u))
        let cutoff = u.fetchedAt.addingTimeInterval(-Self.keep)
        samples.removeAll { $0.t < cutoff }
        save()
    }

    private func save() {
        guard let url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(samples) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
