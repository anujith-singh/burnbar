import AppKit
import BurnbarCore

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Parses hex colours: #RGB, #RRGGBB or #RRGGBBAA (the # is optional).
enum Hex {
    static func parse(_ text: String) -> NSColor? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgba = s.count == 6 ? (v << 8) | 0xFF : v
        return NSColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                       blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}

/// The menu bar item's colours. Built-in values were chosen on real menu bars and are the same for
/// Day and Night and for every screen. All can be overridden in "Customise Appearance…", per theme
/// and per kind of screen: a blank other-screens field uses the active-screen colour, and a blank
/// active-screen field uses the built-in one.
enum ColourSlot: String, CaseIterable {
    case background, border, divider, green, amber, red, flameOutline, flameFill

    var label: String {
        switch self {
        case .background: "Background"
        case .border: "Pill border"
        case .divider: "Divider"
        case .green: "Green text"
        case .amber: "Amber text"
        case .red: "Red text"
        case .flameOutline: "Flame outline"
        case .flameFill: "Flame fill"
        }
    }

    /// Built-in colour. Blank for the flame fill, which follows the session's colour.
    var builtInHex: String {
        switch self {
        case .background: "#253746"
        case .border: "#435A6B"
        case .divider: "#8093A0"
        case .green: "#55D68A"
        case .amber: "#FFC04D"
        case .red: "#FF7070"
        case .flameOutline: "#DCE4E8"
        case .flameFill: ""
        }
    }

    /// Placeholder shown in a blank active-screen field.
    var builtInLabel: String { builtInHex.isEmpty ? "session colour" : builtInHex }

    /// Active-screen keys are "colour.day.green"; other-screens keys are "colour.day.inactive.green".
    func defaultsKey(dark: Bool, inactive: Bool) -> String {
        "colour.\(dark ? "night" : "day").\(inactive ? "inactive." : "")\(rawValue)"
    }

    private func own(dark: Bool, inactive: Bool) -> NSColor? {
        UserDefaults.standard.string(forKey: defaultsKey(dark: dark, inactive: inactive)).flatMap(Hex.parse)
    }

    /// Built-in colour specific to other screens, where one differs from the active screen.
    /// Day theme: macOS renders the item differently off the active screen, so other screens get
    /// their own set, chosen on real displays. The flame fill still follows the session's colour.
    func builtInInactiveHex(dark: Bool) -> String? {
        guard !dark else { return nil }
        switch self {
        case .background: return "#000000"
        case .border: return "#52616D"
        case .divider: return "#8196A7"
        case .green: return "#087C48"
        case .amber: return "#A66A00"
        case .red: return "#C94A4A"
        case .flameOutline: return "#FFFFFF"
        case .flameFill: return nil
        }
    }

    /// The colour for this slot on that kind of screen. Other screens: their own field, else a
    /// built-in other-screens colour, else the active screen's. Active screen: its field, else
    /// built-in. nil only for a flame fill that follows the session.
    func color(dark: Bool, inactive: Bool) -> NSColor? {
        if inactive {
            if let c = own(dark: dark, inactive: true) { return c }
            if let hex = builtInInactiveHex(dark: dark) { return Hex.parse(hex) }
        }
        return own(dark: dark, inactive: false) ?? Hex.parse(builtInHex)
    }
}

enum Palette {
    /// Dropdown colours ("Standard" set: deeper shades for light menus, brighter for dark). Kept
    /// separate from the menu bar colours, which are tuned for the dark pill.
    static func accent(_ level: Level) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex: String
            switch (level, appearance.isDark) {
            case (.green, false): hex = "#1A7F37"
            case (.amber, false): hex = "#B35C00"
            case (.red, false):   hex = "#CF222E"
            case (.green, true):  hex = "#3FD467"
            case (.amber, true):  hex = "#FFC23D"
            case (.red, true):    hex = "#FF6B61"
            }
            return Hex.parse(hex)!
        }
    }

    // Menu bar item colours. `inactive` = drawn for a screen other than the active one.

    static func barText(_ level: Level, dark: Bool, inactive: Bool) -> NSColor {
        slot(level).color(dark: dark, inactive: inactive)!
    }

    static func chip(dark: Bool, inactive: Bool) -> NSColor { ColourSlot.background.color(dark: dark, inactive: inactive)! }
    static func border(dark: Bool, inactive: Bool) -> NSColor { ColourSlot.border.color(dark: dark, inactive: inactive)! }
    static func divider(dark: Bool, inactive: Bool) -> NSColor { ColourSlot.divider.color(dark: dark, inactive: inactive)! }

    /// Flame outline, and its fill: a set fill colour, else the session's own colour (grey if unknown).
    static func flameColours(dark: Bool, inactive: Bool, session: Level?) -> (outline: NSColor, fill: NSColor) {
        let outline = ColourSlot.flameOutline.color(dark: dark, inactive: inactive)!
        let fill = ColourSlot.flameFill.color(dark: dark, inactive: inactive)
            ?? session.map { barText($0, dark: dark, inactive: inactive) }
            ?? greyText(dark: chipLooksDark(dark: dark, inactive: inactive))
        return (outline, fill)
    }

    /// Whether the chip, laid over a typical bar for the theme, comes out dark. Decides the shade of
    /// the stale grey, so it stays readable on whatever background is set.
    static func chipLooksDark(dark: Bool, inactive: Bool) -> Bool {
        guard let c = chip(dark: dark, inactive: inactive).usingColorSpace(.sRGB) else { return dark }
        let bar: CGFloat = dark ? 0.12 : 0.9
        func mix(_ v: CGFloat) -> CGFloat { v * c.alphaComponent + bar * (1 - c.alphaComponent) }
        let luminance = 0.2126 * mix(c.redComponent) + 0.7152 * mix(c.greenComponent) + 0.0722 * mix(c.blueComponent)
        return luminance < 0.45
    }

    static func greyText(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.42) : NSColor(white: 0, alpha: 0.38) }

    private static func slot(_ level: Level) -> ColourSlot {
        switch level { case .green: .green; case .amber: .amber; case .red: .red }
    }
}
