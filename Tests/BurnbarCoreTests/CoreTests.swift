import Foundation
import Testing
@testable import BurnbarCore

private func iso(_ s: String) -> Date { UsageParser.date(s)! }

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct Parsing {
    /// A trimmed, made-up sample with the same structure as the live response (2026-11).
    @Test func sampleResponse() throws {
        let u = try UsageParser.parse(fixture("usage-sample"), fetchedAt: Date())
        #expect(u.session.percent >= 0 && u.session.percent <= 100)
        #expect(u.session.resetsAt != nil)
        #expect(u.week.resetsAt != nil)
        // The live response carried the per-model limit only in limits[] (seven_day_opus/sonnet null).
        #expect(u.otherWeekly.map(\.name) == ["Example Model"])
        #expect(u.surfaces.allSatisfy { $0.percentOfLimit > 0 })
        #expect(u.surfaces.map(\.percentOfLimit) == u.surfaces.map(\.percentOfLimit).sorted(by: >))
    }

    @Test func topLevelModelBucketsAndLimitsFallback() throws {
        let json = """
        {"limits":[{"kind":"session","percent":"12","resets_at":"2026-11-19T17:39:59.5+00:00"},
                   {"kind":"weekly_all","percent":61,"resets_at":"2026-11-21T05:00:00Z"},
                   {"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}],
         "seven_day_opus":{"utilization":40.0,"resets_at":"2026-11-21T05:00:00Z"},
         "seven_day_sonnet":{"utilization":true},
         "seven_day_breakdown":{"rows":[]}}
        """
        let u = try UsageParser.parse(Data(json.utf8), fetchedAt: Date())
        #expect(u.session.percent == 12)                       // numeric string accepted
        #expect(u.session.resetsAt == iso("2026-11-19T17:40:00Z"))
        #expect(u.week.percent == 61)
        // seven_day_opus wins over the duplicate scoped "Opus"; boolean utilization is rejected.
        #expect(u.otherWeekly == [NamedLimit(name: "Opus", percent: 40, resetsAt: iso("2026-11-21T05:00:00Z"))])
    }

    @Test func missingWindowsThrow() {
        #expect(throws: UsageParseError.missing("five_hour")) {
            try UsageParser.parse(Data(#"{"seven_day":{"utilization":1}}"#.utf8), fetchedAt: Date())
        }
        #expect(throws: UsageParseError.notJSONObject) {
            try UsageParser.parse(Data("[1,2]".utf8), fetchedAt: Date())
        }
    }

    @Test func dateRoundingAbsorbsJitter() {
        // Two consecutive real calls returned these for the same window.
        #expect(UsageParser.date("2026-11-19T17:39:59.548527+00:00") == UsageParser.date("2026-11-19T17:40:00.225511+00:00"))
        #expect(UsageParser.date("2026-11-21T05:00:00+00:00") == iso("2026-11-21T05:00:00Z"))
        #expect(UsageParser.date("nonsense") == nil)
    }
}

@Suite struct Levels {
    @Test func sessionThresholds() {
        #expect(Risk.sessionLevel(49.9) == .green)
        #expect(Risk.sessionLevel(50) == .amber)
        #expect(Risk.sessionLevel(79) == .amber)
        #expect(Risk.sessionLevel(80) == .red)
    }

    @Test func weekUsesPaceNotRawPercent() {
        let reset = iso("2026-11-21T05:00:00Z")
        let start = reset.addingTimeInterval(-7 * 86400)
        // 6 days in, 61 % used → projected 71 % → green, though 61 % would be amber by raw thresholds.
        let late = Risk.weekPace(LimitWindow(percent: 61, resetsAt: reset), at: start.addingTimeInterval(6 * 86400))
        #expect(late.level == .green)
        #expect(abs(late.projectedAtReset! - 61 / (6.0 / 7)) < 0.001)
        // 1 day in, 20 % used → projected 140 % → red, though 20 % would be green by raw thresholds.
        let early = Risk.weekPace(LimitWindow(percent: 20, resetsAt: reset), at: start.addingTimeInterval(86400))
        #expect(early.level == .red)
        // 2 days in, 25 % → projected 87.5 % → amber.
        #expect(Risk.weekPace(LimitWindow(percent: 25, resetsAt: reset), at: start.addingTimeInterval(2 * 86400)).level == .amber)
    }

    @Test func weekWarmupFallsBackToSessionThresholds() {
        let reset = iso("2026-11-21T05:00:00Z")
        let start = reset.addingTimeInterval(-7 * 86400)
        // 6 h in, 10 % would project to 280 % — but warm-up uses raw thresholds → green.
        let p = Risk.weekPace(LimitWindow(percent: 10, resetsAt: reset), at: start.addingTimeInterval(6 * 3600))
        #expect(p.level == .green)
        #expect(p.projectedAtReset == nil)
        #expect(Risk.weekPace(LimitWindow(percent: 55, resetsAt: reset), at: start.addingTimeInterval(6 * 3600)).level == .amber)
    }
}

@Suite struct Forecasting {
    let reset = iso("2026-11-21T05:00:00Z")
    let sReset = iso("2026-11-19T17:40:00Z")

    func samples(weekly: [(TimeInterval, Double)], from now: Date) -> [Sample] {
        weekly.map { Sample(t: now.addingTimeInterval(-$0.0), s: 0, sReset: sReset, w: $0.1, wReset: reset) }
    }

    @Test func recentRateDrivesExhaustion() {
        let now = iso("2026-11-19T13:40:00Z")
        // 5 % per hour for the last 4 h; 41 % left → ~8.2 h → before the reset in ~39 h.
        let s = samples(weekly: [(4 * 3600, 39), (2 * 3600, 49), (0, 59)], from: now)
        let w = LimitWindow(percent: 59, resetsAt: reset)
        let eta = Forecast.exhaustion(.week, window: w, samples: s, at: now)
        #expect(eta != nil)
        #expect(abs(eta!.timeIntervalSince(now) - 41.0 / 5 * 3600) < 1)
    }

    @Test func noWarningWhenExhaustionIsAfterReset() {
        let now = iso("2026-11-19T13:40:00Z")
        // 0.5 % per hour, 71 % left → 142 h, after the reset.
        let s = samples(weekly: [(4 * 3600, 27), (0, 29)], from: now)
        #expect(Forecast.exhaustion(.week, window: LimitWindow(percent: 29, resetsAt: reset), samples: s, at: now) == nil)
    }

    @Test func recentRateBeatsAverage() {
        let now = iso("2026-11-19T13:40:00Z")
        // Average since reset is low (29 % over 5.4 days), but the last 2 h burned 10 %.
        let s = samples(weekly: [(2 * 3600, 19), (0, 29)], from: now)
        let w = LimitWindow(percent: 29, resetsAt: reset)
        #expect(Forecast.averageRate(.week, window: w, at: now)! < Forecast.recentRate(.week, window: w, samples: s, at: now)!)
        #expect(Forecast.exhaustion(.week, window: w, samples: s, at: now) != nil)
    }

    @Test func samplesFromAnotherWindowAreIgnored() {
        let now = iso("2026-11-19T13:40:00Z")
        let old = Sample(t: now.addingTimeInterval(-3 * 3600), s: 0, sReset: nil, w: 90, wReset: reset.addingTimeInterval(-7 * 86400))
        let cur = Sample(t: now, s: 0, sReset: nil, w: 5, wReset: reset)
        #expect(Forecast.recentRate(.week, window: LimitWindow(percent: 5, resetsAt: reset), samples: [old, cur], at: now) == nil)
    }

    @Test func tooShortASpanIsNotTrusted() {
        let now = iso("2026-11-19T13:40:00Z")
        let s = samples(weekly: [(30 * 60, 20), (0, 29)], from: now)
        #expect(Forecast.recentRate(.week, window: LimitWindow(percent: 29, resetsAt: reset), samples: s, at: now) == nil)
    }
}

@Suite struct Formatting {
    @Test func countdowns() {
        let now = iso("2026-11-19T13:40:00Z")
        let n = "\u{202F}"   // narrow no-break space between number and unit
        func c(_ minutes: Int) -> String { Format.countdown(to: now.addingTimeInterval(Double(minutes) * 60), from: now) }
        #expect(c(4 * 60 + 50) == "4\(n)h 50\(n)m")
        #expect(c(2 * 60 + 2) == "2\(n)h 2\(n)m")              // no zero-padding
        #expect(c(40 * 60 + 20) == "1\(n)d 16\(n)h")
        #expect(c(23 * 60 + 5) == "23\(n)h 5\(n)m")            // under a day, minutes appear
        #expect(c(42) == "42\(n)m")
        #expect(c(3 * 60) == "3\(n)h")
        #expect(c(48 * 60) == "2\(n)d")
        #expect(Format.countdown(to: now.addingTimeInterval(-5), from: now) == "now")
        // A tick a second late must not drop a minute.
        #expect(Format.countdown(to: now.addingTimeInterval(4 * 3600), from: now.addingTimeInterval(1.5)) == "4\(n)h")
        #expect(Format.countdown(to: .distantFuture, from: now).hasSuffix("h"))   // no trap on huge values
    }

    @Test func ages() {
        #expect(Format.age(10) == "just now")
        #expect(Format.age(25 * 60 + 10) == "25 min ago")
        #expect(Format.age(2 * 3600 + 5 * 60) == "2 h 5 min ago")
    }

    @Test func approxTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let loc = Locale(identifier: "en_US")
        let now = iso("2026-11-19T10:00:00Z")   // Thursday
        #expect(Format.approxTime(iso("2026-11-20T21:10:00Z"), now: now, calendar: cal, locale: loc) == "~Fri 9\u{202F}PM")   // DateFormatter uses U+202F before AM/PM
        #expect(Format.approxTime(iso("2026-11-19T15:08:00Z"), now: now, calendar: cal, locale: loc) == "~3:10\u{202F}PM")
    }
}
