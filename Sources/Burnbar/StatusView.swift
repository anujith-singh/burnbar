import AppKit
import BurnbarCore

struct BarSegment: Equatable {
    var text: String
    /// nil when there is no data for this segment.
    var level: Level?
}

struct BarModel: Equatable {
    var segments: [BarSegment]
    /// Last fetch failed (or data is old): draw everything grey.
    var stale: Bool
    /// Drives the Ember gauge glyph's fill. nil = empty flame.
    var sessionPercent: Double?
}

/// Draws the menu bar item: one capsule (the "pill") holding the flame, S, a divider and W.
/// Lives inside the status item's button so the button keeps handling clicks; this view only paints.
///
/// Layout (measured to what is visible, not to image frames):
///   pad 8 | flame | gap 6 | S | gap 6 | divider | gap 6 | W | pad 8,  3 pt above and below the flame.
///
/// Width across screens. macOS draws the item once per display: a vibrant pass for the active
/// screen, a plain pass for the others. The status item's slot is one width for all screens, set
/// 3 pt narrower than the pill on each side, so on the active screen the pill reaches out to the
/// edge of macOS's click highlight (the "−3 pt" look). Other screens clip drawing at the slot's
/// edges, so there the pill is drawn to fit inside the slot instead (as at "0 pt"), 3 pt shorter at
/// each end, with slightly smaller inner gaps so the ends keep most of their padding.
final class StatusView: NSView {
    var model = BarModel(segments: [], stale: true) {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    /// Menu open: the pill shows its pressed state.
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }

    /// How far the active-screen pill extends past each side of the slot.
    let overhang: CGFloat = 3
    private let padH: CGFloat = 8          // inside the active-screen pill, left and right
    private let padV: CGFloat = 3          // above and below the flame
    private let gap: CGFloat = 6           // between flame, S, divider and W (active screen)
    /// Other screens: the pill is 3 pt shorter at each end, so the inner gaps give up 1 pt each and
    /// the content is re-centred, leaving ~6.5 pt at the ends instead of 5.
    private let inactiveGap: CGFloat = 5
    private let maxGlyph: CGFloat = 18
    /// The flame's ink spans x 16…84 of its 100-unit box (path 20…80 plus half the 8-unit stroke),
    /// so 16 % of its width on each side is empty.
    private let glyphBlank: CGFloat = 0.16

    private var appearanceObservation: NSKeyValueObservation?

    /// Day or night. Inside the menu bar the view's own effectiveAppearance is always a dark one
    /// (DarkAqua / VibrantDark, seen in logs on macOS 27 even on light bars), so the theme comes from
    /// the app's effective appearance, i.e. the system Light/Dark setting. An explicitly set
    /// appearance (offscreen snapshots) wins.
    private var isDark: Bool { (appearance ?? NSApp.effectiveAppearance).isDark }

    /// Which kind of screen this drawing pass is for: vibrant appearance = active screen, plain =
    /// the others (confirmed with a colour-per-pass test on three displays, macOS 27). Offscreen
    /// snapshots set an explicit appearance and count as active.
    private var drawingForInactiveScreen: Bool {
        guard appearance == nil else { return false }
        let name = NSAppearance.currentDrawing().name
        return !(name == .vibrantDark || name == .vibrantLight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                Log.app.notice("system appearance changed: \(NSApp.effectiveAppearance.name.rawValue, privacy: .public)")
                self?.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Colours changed in Customise Appearance: repaint.
    func coloursChanged() { needsDisplay = true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Geometry

    private var font: NSFont {
        // Monospaced digits so the item doesn't jitter as numbers change every minute.
        .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
    }

    private var itemHeight: CGFloat { bounds.height > 0 ? bounds.height : NSStatusBar.system.thickness }
    private var pillHeight: CGFloat { min(itemHeight, maxGlyph + 2 * padV) }

    /// The flame fills the pill's height minus the vertical padding, up to 18 pt.
    private var glyphSize: CGFloat { max(10, min(maxGlyph, pillHeight - 2 * padV)) }
    private var glyphInkWidth: CGFloat { glyphSize * (1 - 2 * glyphBlank) }

    private func width(_ s: String) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    /// The active-screen pill's width, and the view's. Recomputed on every render, so the pill
    /// follows the text length.
    var preferredWidth: CGFloat {
        let texts = model.segments.map { width($0.text) }
        let dividers = CGFloat(max(0, texts.count - 1))
        return 2 * padH + glyphInkWidth + gap + texts.reduce(0, +) + dividers * (gap + 1 + gap)
    }

    /// The status item's slot: the pill minus the overhang on each side.
    var itemLength: CGFloat { max(1, preferredWidth - 2 * overhang) }

    /// Full view width on the active screen; inside the slot on the others.
    private func pillRect(inactive: Bool) -> NSRect {
        let h = pillHeight
        let inset = inactive ? overhang : 0
        return NSRect(x: inset, y: ((itemHeight - h) / 2).rounded(), width: max(0, bounds.width - 2 * inset), height: h)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDark
        let inactive = drawingForInactiveScreen
        let chipDark = Palette.chipLooksDark(dark: dark, inactive: inactive)
        let pill = pillRect(inactive: inactive)

        let capsule = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        Palette.chip(dark: dark, inactive: inactive).setFill()
        capsule.fill()
        if highlighted {
            (chipDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)).setFill()
            capsule.fill()
        }
        let ring = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: (pill.height - 1) / 2, yRadius: (pill.height - 1) / 2)
        ring.lineWidth = 1
        Palette.border(dark: dark, inactive: inactive).setStroke()
        ring.stroke()

        // Content: flame, then S | W. Centred in the pill with the screen's gap size.
        let g = inactive ? inactiveGap : gap
        let texts = model.segments.map { width($0.text) }
        let contentWidth = glyphInkWidth + g + texts.reduce(0, +) + CGFloat(max(0, texts.count - 1)) * (2 * g + 1)
        let start = pill.minX + ((pill.width - contentWidth) / 2).rounded()

        let size = glyphSize
        let glyphRect = NSRect(x: start - size * glyphBlank, y: pill.midY - size / 2, width: size, height: size)
        let flame = Palette.flameColours(dark: dark, inactive: inactive, session: model.segments.first?.level)
        let alpha: CGFloat = model.stale ? 0.45 : 1
        Glyph.draw(in: glyphRect, sessionPercent: model.sessionPercent.map { $0.rounded() },
                   outline: flame.outline.withAlphaComponent(flame.outline.alphaComponent * alpha),
                   fill: flame.fill.withAlphaComponent(flame.fill.alphaComponent * alpha))

        let grey = Palette.greyText(dark: chipDark)
        // Text centred on its cap height, so letters (not the line box) sit in the middle.
        let textY = pixelRound(pill.midY - font.capHeight / 2) + font.descender

        var x = start + glyphInkWidth + g
        for (i, seg) in model.segments.enumerated() {
            if i > 0 {
                let h = font.capHeight + 4
                Palette.divider(dark: dark, inactive: inactive).setFill()
                NSRect(x: x, y: pixelRound(pill.midY - h / 2), width: 1, height: h).fill()
                x += 1 + g
            }
            let color = (model.stale || seg.level == nil) ? grey : Palette.barText(seg.level!, dark: dark, inactive: inactive)
            NSAttributedString(string: seg.text, attributes: [.font: font, .foregroundColor: color])
                .draw(at: NSPoint(x: x, y: textY))
            x += texts[i] + g
        }
    }

    private func pixelRound(_ v: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (v * scale).rounded() / scale
    }
}
