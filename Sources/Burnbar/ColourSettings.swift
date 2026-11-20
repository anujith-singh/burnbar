import SwiftUI
import AppKit

/// "Customise Appearance…": hex fields for the menu bar item, per theme and per kind of screen.
/// Values are stored in UserDefaults and the menu bar repaints as you type.
/// Blank active-screen field = built-in colour; blank other-screens field = same as active.
struct ColourSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Day (Light)").font(.headline).gridCellColumns(2)
                    Text("Night (Dark)").font(.headline).gridCellColumns(2)
                }
                GridRow {
                    Text("")
                    ForEach(0..<2) { _ in
                        Text("Active screen").font(.caption).foregroundStyle(.secondary)
                        Text("Other screens").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(ColourSlot.allCases, id: \.self) { slot in
                    GridRow {
                        Text(slot.label)
                        HexField(slot: slot, dark: false, inactive: false)
                        HexField(slot: slot, dark: false, inactive: true)
                        HexField(slot: slot, dark: true, inactive: false)
                        HexField(slot: slot, dark: true, inactive: true)
                    }
                }
            }
            Text("Use #RRGGBB, or #RRGGBBAA where the last two digits set opacity (00 clear, FF solid). \"Active screen\" is the display you're working on; macOS treats Burnbar differently on the others, so they can have their own colours. A blank field uses the built-in colour shown greyed in it; \"same as active\" means the active-screen colour. A blank flame fill takes the session's green, amber or red.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Reset All to Defaults") {
                    for slot in ColourSlot.allCases {
                        for dark in [false, true] {
                            for inactive in [false, true] {
                                UserDefaults.standard.removeObject(forKey: slot.defaultsKey(dark: dark, inactive: inactive))
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 720)
    }
}

private struct HexField: View {
    let slot: ColourSlot
    let dark: Bool
    let inactive: Bool
    @AppStorage private var text: String
    /// The active-screen value; an other-screens field falls back to it, so its swatch must follow it.
    @AppStorage private var activeText: String

    init(slot: ColourSlot, dark: Bool, inactive: Bool) {
        self.slot = slot
        self.dark = dark
        self.inactive = inactive
        _text = AppStorage(wrappedValue: "", slot.defaultsKey(dark: dark, inactive: inactive))
        _activeText = AppStorage(wrappedValue: "", slot.defaultsKey(dark: dark, inactive: false))
    }

    private var isInvalid: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && Hex.parse(text) == nil }

    var body: some View {
        let _ = activeText   // re-render when the active-screen value changes
        HStack(spacing: 6) {
            Swatch(color: slot.color(dark: dark, inactive: inactive), dark: dark)
            TextField(inactive ? (slot.builtInInactiveHex(dark: dark) ?? "same as active") : slot.builtInLabel, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 104)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(isInvalid ? Color.red : .clear, lineWidth: 1.5))
                .help(isInvalid ? "Not a hex colour; using the default" : "")
        }
    }
}

/// Colour preview on the theme's typical bar shade, so translucent colours look as they will.
/// "S" marks a flame fill that follows the session's colour.
private struct Swatch: View {
    let color: NSColor?
    let dark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(dark ? Color(white: 0.12) : Color(white: 0.9))
            RoundedRectangle(cornerRadius: 4).fill(color.map { Color(nsColor: $0) } ?? .clear)
            if color == nil { Text("S").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(width: 18, height: 18)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
    }
}
