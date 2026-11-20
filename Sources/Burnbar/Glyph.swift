import AppKit

/// The "Ember gauge" menu bar glyph: a flame outline whose inside fills from the bottom up to the
/// session percentage. Drawn by the bar view in the pill's colours (outline, and a fill that follows
/// the session's colour by default), once per screen.
enum Glyph {
    /// The flame, in the reference SVG's 100×100 y-down space.
    static let flamePath = "M50 6 C61 24 80 37 80 60 C80 79 66 94 50 94 C34 94 20 79 20 60 C20 47 28 39 33 30 C35 41 41 47 45 49 C43 35 44 20 50 6 Z"

    /// Draws the flame into `rect` of a non-flipped view, in the given colours.
    static func draw(in rect: NSRect, sessionPercent: Double?, outline: NSColor, fill: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / 100, y: -rect.height / 100)   // into the SVG's y-down space
        draw(in: ctx, sessionPercent: sessionPercent, outline: outline.cgColor, fill: fill.cgColor)
        ctx.restoreGState()
    }

    /// Core drawing in the 100×100 y-down space.
    private static func draw(in ctx: CGContext, sessionPercent: Double?, outline: CGColor, fill: CGColor) {
        let pct = min(100, max(0, sessionPercent ?? 0))
        let flame = SVGPath.cgPath(flamePath)

        // Fill: clip rect y = 94 − 0.88 × session% (flame spans y 6…94).
        let top = 94 - 0.88 * pct
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: top, width: 100, height: 100 - top))
        ctx.addPath(flame)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()

        // Outline, always visible.
        ctx.addPath(flame)
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(8)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
}

/// Minimal SVG path parser for the absolute M / C / L / Z commands the logo uses.
enum SVGPath {
    static func cgPath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var current = ""
        for ch in d {
            if ch.isLetter {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch == " " || ch == "," {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var i = 0
        var cmd = ""
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        while i < tokens.count {
            if tokens[i].first?.isLetter == true { cmd = tokens[i]; i += 1 }
            switch cmd {
            case "M": path.move(to: CGPoint(x: num(), y: num())); cmd = "L"
            case "L": path.addLine(to: CGPoint(x: num(), y: num()))
            case "C":
                let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num()), p = CGPoint(x: num(), y: num())
                path.addCurve(to: p, control1: c1, control2: c2)
            case "Z", "z": path.closeSubpath()
            default: i += 1
            }
        }
        return path
    }
}
