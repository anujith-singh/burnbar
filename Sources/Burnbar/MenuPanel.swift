import SwiftUI
import BurnbarCore

/// Everything the dropdown's info panel shows, precomputed so the view stays dumb.
struct PanelModel {
    struct Gauge {
        var title: String
        var subtitle: String
        var percent: Double
        var level: Level?
        /// Even-pace position (0–100) drawn as a tick on the weekly bar.
        var marker: Double?
        var resetLine: String
        var paceLine: String?
        var paceLevel: Level?
        var warning: String?
    }

    var banner: (title: String, body: String)?
    var session: Gauge?
    var week: Gauge?
    var others: [(name: String, detail: String)] = []
    var surfaces: String?
    var footer: String
    var footerIsError: Bool
    var stale: Bool
}

/// Everything the panel is built from; kept separate so snapshots render the real builder.
struct PanelInputs {
    var usage: Usage?
    var samples: [Sample]
    var lastError: String?
    var signedOutReason: String?
    var stale = false
    var paused: Bool
    var nextFetchAt: Date?
    var onAC: Bool
}

extension PanelModel {
    static func build(_ i: PanelInputs, now: Date) -> PanelModel {
        var m = PanelModel(footer: "", footerIsError: false, stale: i.stale || i.lastError != nil)

        if let reason = i.signedOutReason {
            m.banner = ("Can't read your Claude usage", reason)   // each reason says what to do
        }

        if let u = i.usage {
            let samples = i.samples
            func resetLine(_ w: LimitWindow) -> String {
                guard let r = w.resetsAt else { return "Reset time unknown" }
                return "Resets \(Format.resetTime(r, now: now)) · in \(Format.countdown(to: r, from: now))"
            }
            func warning(_ k: LimitKind, _ w: LimitWindow) -> String? {
                if w.percent >= 100 { return "Limit reached" }
                guard let eta = Forecast.exhaustion(k, window: w, samples: samples, at: u.fetchedAt) else { return nil }
                // Old data can forecast a time that has already passed.
                if eta <= now { return "At this rate you've probably hit the limit" }
                return "At this rate you'll hit the limit \(Format.approxTime(eta, now: now))"
            }

            m.session = .init(title: "Session", subtitle: "5-hour window", percent: u.session.percent,
                              level: Risk.sessionLevel(u.session.percent), marker: nil,
                              resetLine: resetLine(u.session), paceLine: nil, paceLevel: nil,
                              warning: warning(.session, u.session))

            let pace = Risk.weekPace(u.week, at: u.fetchedAt)
            var paceLine: String
            if let projected = pace.projectedAtReset, let even = pace.evenPaceNow {
                let verdict = projected >= 100 ? "over the limit" : projected >= 80 ? "close to the limit" : "on track"
                paceLine = "Pace ~\(Format.percent(min(projected, 999))) at reset (\(verdict)) · even \(Format.percent(even))"
            } else {
                paceLine = "Pace: too early to tell — first 12 h after reset"
            }
            m.week = .init(title: "Week", subtitle: "all models", percent: u.week.percent, level: pace.level,
                           marker: pace.evenPaceNow, resetLine: resetLine(u.week), paceLine: paceLine,
                           paceLevel: pace.projectedAtReset == nil ? nil : pace.level,
                           warning: warning(.week, u.week))

            m.others = u.otherWeekly.map { o in
                var detail = Format.percent(o.percent)
                if let r = o.resetsAt, !Forecast.sameWindow(r, u.week.resetsAt) {
                    detail += " · resets \(Format.resetTime(r, now: now))"
                }
                return (o.name, detail)
            }
            if !u.surfaces.isEmpty {
                // Non-breaking spaces keep each "name percent" group on one line; lines break only
                // between groups.
                let nb = "\u{00A0}"
                m.surfaces = "Weekly limit used by: " + u.surfaces
                    .map { $0.name.replacingOccurrences(of: " ", with: nb) + nb + Format.percent($0.percentOfLimit) }
                    .joined(separator: " · ")
            }

            let age = Format.age(now.timeIntervalSince(u.fetchedAt))
            if let error = i.lastError, i.signedOutReason == nil {
                m.footer = "Couldn't refresh (\(error)) · updated \(age)"
                m.footerIsError = true
            } else {
                m.footer = "Updated \(age)"
            }
        } else {
            if i.signedOutReason != nil {
                m.footer = "Picks up the new sign-in automatically"   // the banner already says why
            } else {
                m.footer = i.lastError.map { "Couldn't load usage: \($0)" } ?? "Loading…"
                m.footerIsError = i.lastError != nil
            }
        }

        if i.paused {
            m.footer += " · paused"
        } else if let next = i.nextFetchAt {
            let c = Format.countdown(to: next, from: now)
            m.footer += c == "now" ? " · checking now" : " · next check in \(c)"
        }
        if !i.onAC { m.footer += " (on battery)" }
        return m
    }

}

struct MenuPanel: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = model.banner {
                VStack(alignment: .leading, spacing: 3) {
                    Label(banner.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Palette.accent(.amber)))
                    Text(banner.body)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let g = model.session { GaugeView(gauge: g, stale: model.stale) }
            if let g = model.week { GaugeView(gauge: g, stale: model.stale) }

            if !model.others.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Other weekly limits").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(model.others.indices, id: \.self) { i in
                        HStack {
                            Text(model.others[i].name)
                            Spacer()
                            Text(model.others[i].detail).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            if let surfaces = model.surfaces {
                Text(surfaces)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.footer)
                .font(.system(size: 11))
                .foregroundStyle(model.footerIsError ? Color(nsColor: Palette.accent(.amber)) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: 300, alignment: .leading)
    }
}

private struct GaugeView: View {
    let gauge: PanelModel.Gauge
    let stale: Bool

    private var tint: Color {
        guard let level = gauge.level, !stale else { return .secondary }
        return Color(nsColor: Palette.accent(level))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(gauge.title).font(.system(size: 13, weight: .semibold))
                Text(gauge.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(gauge.percent))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                // Bars pinned to 6 pt; the even-pace tick is an overlay, so it can't stretch them.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 6)
                    Capsule().fill(tint).frame(width: max(0, geo.size.width * gauge.percent / 100), height: 6)
                }
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    if let m = gauge.marker {
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5, height: 10)
                            .offset(x: geo.size.width * min(100, m) / 100 - 0.75)
                    }
                }
            }
            .frame(height: 6)
            .padding(.vertical, 2)

            Text(gauge.resetLine).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            if let pace = gauge.paceLine {
                Text(pace)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(gauge.paceLevel.map { stale ? Color.secondary : Color(nsColor: Palette.accent($0)) } ?? .secondary)
            }
            if let w = gauge.warning {
                Label(w, systemImage: "flame.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stale ? Color.secondary : Color(nsColor: Palette.accent(.red)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
