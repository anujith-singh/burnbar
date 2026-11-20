import Foundation

public enum Level: Sendable, Equatable {
    case green, amber, red
}

public enum LimitKind: Sendable {
    case session, week

    /// Length of the rolling window.
    public var length: TimeInterval { self == .session ? 5 * 3600 : 7 * 86400 }
    /// How far back "recent" samples reach when estimating the burn rate.
    var lookback: TimeInterval { self == .session ? 3600 : 6 * 3600 }
    /// The recent samples must span at least this long to be trusted.
    var minSpan: TimeInterval { self == .session ? 15 * 60 : 3600 }
    /// The average-since-reset rate is only used once this much of the window has elapsed.
    var minElapsedForAverage: TimeInterval { self == .session ? 20 * 60 : 12 * 3600 }
}

public enum Risk {
    /// Session thresholds: green < 50 %, amber 50–80 %, red ≥ 80 %.
    public static func sessionLevel(_ percent: Double) -> Level {
        percent >= 80 ? .red : percent >= 50 ? .amber : .green
    }

    public struct WeekPace: Sendable, Equatable {
        public var level: Level
        /// Projected usage at reset if the average pace since reset continues. nil during warm-up.
        public var projectedAtReset: Double?
        /// What usage would be now at a perfectly even pace (elapsed fraction × 100).
        public var evenPaceNow: Double?
    }

    /// Weekly colour is by pace: projected usage at reset, from the average rate since the window
    /// opened. A week includes nights and weekends, so the since-reset average is the right basis for
    /// "where will I land"; the short-term rate is used separately for the "you'll hit it at …" forecast.
    /// For the first 12 h after a reset there is too little signal, so the session thresholds apply.
    public static func weekPace(_ w: LimitWindow, at t: Date) -> WeekPace {
        guard let reset = w.resetsAt else {
            return WeekPace(level: sessionLevel(w.percent), projectedAtReset: nil, evenPaceNow: nil)
        }
        let length = LimitKind.week.length
        let elapsed = t.timeIntervalSince(reset.addingTimeInterval(-length))
        guard elapsed >= 12 * 3600 else {
            return WeekPace(level: sessionLevel(w.percent), projectedAtReset: nil,
                            evenPaceNow: max(0, elapsed / length * 100))
        }
        let fraction = min(1, elapsed / length)
        let projected = w.percent / fraction
        let level: Level = (projected >= 100 || w.percent >= 95) ? .red : projected >= 80 ? .amber : .green
        return WeekPace(level: level, projectedAtReset: projected, evenPaceNow: fraction * 100)
    }
}

/// One stored observation, used to estimate the recent burn rate.
public struct Sample: Codable, Sendable, Equatable {
    public var t: Date
    public var s: Double
    public var sReset: Date?
    public var w: Double
    public var wReset: Date?

    public init(t: Date, s: Double, sReset: Date?, w: Double, wReset: Date?) {
        self.t = t; self.s = s; self.sReset = sReset; self.w = w; self.wReset = wReset
    }

    public init(_ u: Usage) {
        self.init(t: u.fetchedAt, s: u.session.percent, sReset: u.session.resetsAt,
                  w: u.week.percent, wReset: u.week.resetsAt)
    }

    func percent(_ k: LimitKind) -> Double { k == .session ? s : w }
    func reset(_ k: LimitKind) -> Date? { k == .session ? sReset : wReset }
}

public enum Forecast {
    /// Two reset timestamps describe the same window if they are within two minutes.
    public static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) <= 120
    }

    /// Percent per second over the recent samples of the current window, or nil if there are too few.
    public static func recentRate(_ k: LimitKind, window: LimitWindow, samples: [Sample], at t: Date) -> Double? {
        let recent = samples
            .filter { sameWindow($0.reset(k), window.resetsAt) && $0.t >= t.addingTimeInterval(-k.lookback) && $0.t <= t }
            .sorted { $0.t < $1.t }
        guard let first = recent.first, let last = recent.last else { return nil }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= k.minSpan else { return nil }
        return max(0, (last.percent(k) - first.percent(k)) / span)
    }

    /// Percent per second averaged since the window opened.
    public static func averageRate(_ k: LimitKind, window: LimitWindow, at t: Date) -> Double? {
        guard let reset = window.resetsAt else { return nil }
        let elapsed = t.timeIntervalSince(reset.addingTimeInterval(-k.length))
        guard elapsed >= k.minElapsedForAverage else { return nil }
        return window.percent / elapsed
    }

    /// When the limit will be hit at the recent rate, only if that is before the reset.
    /// Falls back to the since-reset average only when there are not yet enough recent samples.
    public static func exhaustion(_ k: LimitKind, window: LimitWindow, samples: [Sample], at t: Date) -> Date? {
        guard let reset = window.resetsAt, window.percent < 100 else { return nil }
        guard let rate = recentRate(k, window: window, samples: samples, at: t)
                ?? averageRate(k, window: window, at: t),
              rate > 0 else { return nil }
        let eta = t.addingTimeInterval((100 - window.percent) / rate)
        return eta < reset ? eta : nil
    }
}

public enum Format {
    /// Notion-style: "2\u{202F}h 2\u{202F}m", "1\u{202F}d 13\u{202F}h", "42\u{202F}m". A narrow no-break space
    /// joins each number to its unit and a normal space separates components; no zero-padding.
    /// Under a day, minutes appear; from a day up, hours are the smallest unit.
    public static func countdown(to target: Date, from now: Date) -> String {
        let raw = target.timeIntervalSince(now) / 60
        guard raw.isFinite else { return "–" }
        let minutes = Int(min(1_000_000, raw).rounded())
        guard minutes > 0 else { return "now" }
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        func unit(_ n: Int, _ u: String) -> String { "\(n)\u{202F}\(u)" }
        if d > 0 { return h > 0 ? "\(unit(d, "d")) \(unit(h, "h"))" : unit(d, "d") }
        if h > 0 { return m > 0 ? "\(unit(h, "h")) \(unit(m, "m"))" : unit(h, "h") }
        return unit(m, "m")
    }

    public static func percent(_ p: Double) -> String {
        guard p.isFinite else { return "–%" }
        return "\(Int(min(9999, max(-9999, p)).rounded()))%"
    }

    /// "just now", "1 min ago", "25 min ago", "2 h 5 min ago", "3 days ago".
    public static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h) h ago" : "\(h) h \(m % 60) min ago" }
        let d = h / 24
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    /// Exact reset time: "6:40 PM" today, otherwise "Sat 21 Nov, 10:30 AM" (locale-aware).
    public static func resetTime(_ d: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(d, inSameDayAs: now) ? "jmm" : "EEEdMMMjmm")
        return f.string(from: d)
    }

    /// Forecast time, deliberately approximate: "~3:10 PM" (5-min rounding) when today,
    /// otherwise "~Fri 9 PM" (rounded to the hour).
    public static func approxTime(_ d: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(d, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
            let rounded = Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 300).rounded() * 300)
            return "~" + f.string(from: rounded)
        }
        f.setLocalizedDateFormatFromTemplate("EEEj")
        let rounded = Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded() * 3600)
        return "~" + f.string(from: rounded)
    }
}
