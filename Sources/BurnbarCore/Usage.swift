import Foundation

/// One rate-limit window: how much is used and when it resets.
public struct LimitWindow: Sendable, Equatable, Codable {
    /// 0–100.
    public var percent: Double
    /// Rounded to the nearest minute (the API returns values with sub-second jitter between calls).
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// An extra weekly limit, e.g. a per-model bucket.
public struct NamedLimit: Sendable, Equatable {
    public var name: String
    public var percent: Double
    public var resetsAt: Date?

    public init(name: String, percent: Double, resetsAt: Date?) {
        self.name = name; self.percent = percent; self.resetsAt = resetsAt
    }
}

/// Share of the weekly limit used by one surface (Claude Code, Chats, …).
public struct SurfaceShare: Sendable, Equatable {
    public var name: String
    public var percentOfLimit: Double

    public init(name: String, percentOfLimit: Double) {
        self.name = name; self.percentOfLimit = percentOfLimit
    }
}

public struct Usage: Sendable, Equatable {
    public var session: LimitWindow
    public var week: LimitWindow
    public var otherWeekly: [NamedLimit]
    public var surfaces: [SurfaceShare]
    public var fetchedAt: Date

    public init(session: LimitWindow, week: LimitWindow, otherWeekly: [NamedLimit] = [],
                surfaces: [SurfaceShare] = [], fetchedAt: Date) {
        self.session = session
        self.week = week
        self.otherWeekly = otherWeekly
        self.surfaces = surfaces
        self.fetchedAt = fetchedAt
    }
}

public enum UsageParseError: Error, Equatable, CustomStringConvertible {
    case notJSONObject
    case missing(String)

    public var description: String {
        switch self {
        case .notJSONObject: "Unexpected response (not a JSON object)"
        case .missing(let k): "Unexpected response (no \(k))"
        }
    }
}

/// Parses `GET /api/oauth/usage`. The endpoint is undocumented, so every field is optional
/// and the parser falls back between the two shapes seen in the wild:
/// top-level `five_hour` / `seven_day` / `seven_day_<name>` objects, and the `limits[]` array.
public enum UsageParser {
    public static func parse(_ data: Data, fetchedAt: Date) throws -> Usage {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.notJSONObject
        }
        let limits = (top["limits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }

        func fromLimits(kind: String) -> LimitWindow? {
            guard let l = limits.first(where: { $0["kind"] as? String == kind }),
                  let p = number(l["percent"]) else { return nil }
            return LimitWindow(percent: clamp(p), resetsAt: date(l["resets_at"]))
        }

        guard let session = window(top["five_hour"]) ?? fromLimits(kind: "session") else {
            throw UsageParseError.missing("five_hour")
        }
        guard let week = window(top["seven_day"]) ?? fromLimits(kind: "weekly_all") else {
            throw UsageParseError.missing("seven_day")
        }

        var others: [NamedLimit] = []
        // Top-level per-model buckets: seven_day_opus, seven_day_sonnet, … (null when not applicable).
        for (key, value) in top where key.hasPrefix("seven_day_") {
            guard let w = window(value) else { continue }
            others.append(NamedLimit(name: prettyName(String(key.dropFirst("seven_day_".count))),
                                     percent: w.percent, resetsAt: w.resetsAt))
        }
        // Scoped weekly limits in limits[] (this is where the per-model limit actually appears today).
        for l in limits where (l["kind"] as? String)?.hasPrefix("weekly_scoped") == true {
            guard let p = number(l["percent"]) else { continue }
            let name = scopeName(l["scope"]) ?? "Scoped"
            if others.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { continue }
            others.append(NamedLimit(name: name, percent: clamp(p), resetsAt: date(l["resets_at"])))
        }
        others.sort { $0.name < $1.name }

        var surfaces: [SurfaceShare] = []
        if let breakdown = top["seven_day_breakdown"] as? [String: Any],
           let rows = breakdown["rows"] as? [Any] {
            for case let row as [String: Any] in rows {
                guard let name = row["display_name"] as? String,
                      let p = number(row["percent_of_limit"]), p > 0 else { continue }
                surfaces.append(SurfaceShare(name: name, percentOfLimit: clamp(p)))
            }
            surfaces.sort { $0.percentOfLimit > $1.percentOfLimit }
        }

        return Usage(session: session, week: week, otherWeekly: others, surfaces: surfaces, fetchedAt: fetchedAt)
    }

    static func window(_ any: Any?) -> LimitWindow? {
        guard let o = any as? [String: Any], let u = number(o["utilization"]) else { return nil }
        return LimitWindow(percent: clamp(u), resetsAt: date(o["resets_at"]))
    }

    static func scopeName(_ any: Any?) -> String? {
        guard let scope = any as? [String: Any] else { return nil }
        for key in ["model", "surface"] {
            if let s = scope[key] as? String, !s.isEmpty { return s }
            if let o = scope[key] as? [String: Any] {
                if let s = o["display_name"] as? String, !s.isEmpty { return s }
                if let s = o["id"] as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }

    static func prettyName(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func clamp(_ p: Double) -> Double { min(100, max(0, p)) }

    /// Accepts JSON numbers (not booleans) and numeric strings.
    public static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = any as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    /// ISO-8601 with optional fractional seconds of any length, rounded to the nearest minute.
    public static func date(_ any: Any?) -> Date? {
        guard var s = any as? String else { return nil }
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? s.endIndex
            fraction = Double("0" + s[dot..<end]) ?? 0
            s.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s) else { return nil }
        return roundToMinute(d.addingTimeInterval(fraction))
    }

    public static func roundToMinute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
    }
}
