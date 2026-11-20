import AppKit
import SwiftUI
import BurnbarCore

/// Offscreen render of the real StatusView under forced appearances.
@MainActor
enum Snapshot {
    /// Bar text built with the real formatter, so snapshots can't drift from the app.
    private static func seg(_ label: String, _ pct: Int, minutes: Int, _ level: Level) -> BarSegment {
        let now = Date(timeIntervalSince1970: 0)
        return BarSegment(text: "\(label) \(pct)% · " + Format.countdown(to: now.addingTimeInterval(Double(minutes) * 60), from: now), level: level)
    }

    static let rows: [(name: String, model: BarModel)] = [
        ("Calm", BarModel(segments: [seg("S", 22, minutes: 240, .green), seg("W", 29, minutes: 39 * 60, .green)], stale: false, sessionPercent: 22)),
        ("Warming", BarModel(segments: [seg("S", 63, minutes: 130, .amber), seg("W", 61, minutes: 76 * 60, .amber)], stale: false, sessionPercent: 63)),
        ("Hot", BarModel(segments: [seg("S", 91, minutes: 48, .red), seg("W", 88, minutes: 22 * 60 + 5, .red)], stale: false, sessionPercent: 91)),
        ("Mixed", BarModel(segments: [seg("S", 84, minutes: 65, .red), seg("W", 61, minutes: 40 * 60, .green)], stale: false, sessionPercent: 84)),
        ("Stale", BarModel(segments: [seg("S", 42, minutes: 290, .green), seg("W", 61, minutes: 40 * 60, .amber)], stale: true, sessionPercent: 42)),
    ]

    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (appearanceName, appearance, background) in [
            ("light", NSAppearance.Name.aqua, NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)),
            ("dark", NSAppearance.Name.darkAqua, NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)),
        ] {
            let image = sheet(appearance: NSAppearance(named: appearance)!, background: background)
            let url = outputDirectory.appendingPathComponent("bar-\(appearanceName).png")
            try? image.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            let panel = panelSheet(appearance: NSAppearance(named: appearance)!,
                                   background: appearanceName == "dark" ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1))
            let purl = outputDirectory.appendingPathComponent("panel-\(appearanceName).png")
            try? panel.representation(using: .png, properties: [:])?.write(to: purl)
            print(purl.path)
        }
    }

    /// The dropdown panel in three states, built by the real PanelModel.build.
    private static func panelSheet(appearance: NSAppearance, background: NSColor) -> NSBitmapImageRep {
        let now = Date()
        let sReset = UsageParser.roundToMinute(now.addingTimeInterval(3 * 3600 + 20 * 60))
        let wReset = UsageParser.roundToMinute(now.addingTimeInterval(36 * 3600))
        let usage = Usage(session: LimitWindow(percent: 58, resetsAt: sReset),
                          week: LimitWindow(percent: 71, resetsAt: wReset),
                          otherWeekly: [NamedLimit(name: "Example Model", percent: 12, resetsAt: wReset)],
                          surfaces: [SurfaceShare(name: "Claude Code", percentOfLimit: 44),
                                     SurfaceShare(name: "Cowork", percentOfLimit: 21),
                                     SurfaceShare(name: "Chats", percentOfLimit: 6)],
                          fetchedAt: now)
        // Last 5 h: weekly went 61 → 71 %, session 30 → 58 %.
        let samples = stride(from: 5.0, through: 0, by: -1).map { h in
            Sample(t: now.addingTimeInterval(-h * 3600), s: 58 - h * 5.6, sReset: sReset, w: 71 - h * 2, wReset: wReset)
        }
        let inputs = [
            PanelInputs(usage: usage, samples: samples, lastError: nil, signedOutReason: nil, paused: false,
                        nextFetchAt: now.addingTimeInterval(240), onAC: true),
            PanelInputs(usage: Usage(session: usage.session, week: usage.week, otherWeekly: usage.otherWeekly,
                                     surfaces: usage.surfaces, fetchedAt: now.addingTimeInterval(-25 * 60)),
                        samples: [], lastError: "Offline", signedOutReason: nil, paused: false,
                        nextFetchAt: now.addingTimeInterval(60), onAC: false),
            PanelInputs(usage: nil, samples: [], lastError: "x", signedOutReason: SignInMessage.notRenewed,
                        paused: false, nextFetchAt: now.addingTimeInterval(300), onAC: true),
        ]
        let hosts = inputs.map { input -> NSHostingView<MenuPanel> in
            let h = NSHostingView(rootView: MenuPanel(model: PanelModel.build(input, now: now)))
            h.appearance = appearance
            h.frame.size = h.fittingSize
            h.layoutSubtreeIfNeeded()
            return h
        }
        let gap: CGFloat = 16
        let width = hosts.reduce(gap) { $0 + $1.frame.width + gap }
        let height = (hosts.map(\.frame.height).max() ?? 100) + 2 * gap
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            NSColor(white: 0.5, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var x = gap
            for h in hosts {
                background.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: height - gap - h.frame.height, width: h.frame.width, height: h.frame.height),
                             xRadius: 8, yRadius: 8).fill()
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: x, yBy: height - gap - h.frame.height)
                t.concat()
                h.displayIgnoringOpacity(h.bounds, in: NSGraphicsContext.current!)
                NSGraphicsContext.restoreGraphicsState()
                x += h.frame.width + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func sheet(appearance: NSAppearance, background: NSColor) -> NSBitmapImageRep {
        let barHeight: CGFloat = 24, labelWidth: CGFloat = 90, rowGap: CGFloat = 6, margin: CGFloat = 12
        let columns = [appearance.isDark ? "Night" : "Day"]
        let views = columns.map { _ in rows.map { row -> StatusView in
            let v = StatusView(frame: .zero)
            v.appearance = appearance
            v.model = row.model
            v.frame = NSRect(x: 0, y: 0, width: v.preferredWidth, height: barHeight)
            v.layoutSubtreeIfNeeded()
            return v
        } }
        let colWidth = (views.flatMap { $0 }.map(\.frame.width).max() ?? 200) + 16
        let width = margin * 2 + labelWidth + colWidth * CGFloat(columns.count)
        let headerHeight: CGFloat = 20
        let height = margin * 2 + headerHeight + CGFloat(rows.count) * (barHeight + rowGap)

        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            let header: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
            for (c, title) in columns.enumerated() {
                NSAttributedString(string: title, attributes: header)
                    .draw(at: NSPoint(x: margin + labelWidth + CGFloat(c) * colWidth + 2, y: height - margin - 14))
            }
            for (r, row) in rows.enumerated() {
                let y = height - margin - headerHeight - CGFloat(r + 1) * (barHeight + rowGap) + rowGap
                NSAttributedString(string: row.name, attributes: label).draw(at: NSPoint(x: margin, y: y + 5))
                for c in columns.indices {
                    let v = views[c][r]
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform()
                    t.translateX(by: margin + labelWidth + CGFloat(c) * colWidth, yBy: y)
                    t.concat()
                    v.displayIgnoringOpacity(v.bounds, in: NSGraphicsContext.current!)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
