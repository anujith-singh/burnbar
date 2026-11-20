# Burnbar

A macOS menu bar app (Swift, AppKit + SwiftUI, no Dock icon) showing Claude subscription usage:
session (S) and weekly (W) %, reset countdowns, colour-coded by risk, in a pill with a flame gauge.
Its look was tuned on real menu bars across several displays.

**Read `docs/DECISIONS.md` before changing anything visual, the colours, the refresh policy or the
data source.** It records what was measured on real menu bars and what was decided, including
fixes that look obvious but were tried and failed. `README.md` is the user-facing summary.

## Build, test, install

```bash
./install.sh            # release build, bundle, icon, ad-hoc sign, install to ~/Applications, relaunch
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
.build/release/Burnbar --snapshot docs/screenshots   # offscreen renders (always the active-screen look)
/usr/bin/log show --last 10m --predicate 'subsystem == "com.burnbar.Burnbar"' --style compact
```

- With only the Command Line Tools, the test command needs that plugin path (Swift Testing's macro
  plugin sits in a subfolder the build doesn't search). With full Xcode, `swift test` works.
- Use `/usr/bin/log`: zsh has a `log` builtin. App logs are `.notice` so they persist.
- `--snapshot` accepts `-colour.day.background "#RRGGBB"` style arguments to preview colours
  without touching saved settings.

## Rules that must not regress

- **Never refresh or write the Claude Code OAuth token.** Read-only, via `/usr/bin/security`.
  Refreshing rotates the refresh token and signs Claude Code out.
- The theme comes from `NSApp.effectiveAppearance`, **not** the view's appearance (always dark in
  the menu bar on macOS 27). Active vs other screens is detected from the drawing pass
  (`NSAppearance.currentDrawing()` vibrant = active). See DECISIONS §5.
- The built-in colours (DECISIONS §7), the 3 pt overhang and the layout constants in
  `StatusView.swift` were chosen deliberately on real screens. Don't change them as a side effect of
  other work.
- Keep "Customise Appearance…"; it is intentional.
- Countdown format is Notion style with U+202F (`2 h 2 m`, `1 d 13 h`).
- Tests use the trimmed sample fixture. Never commit a real API response: it contains
  account-specific billing state and undocumented internal fields.

## Verifying changes

- Menu bar appearance can't be checked from offscreen renders alone: `--snapshot` never shows the
  other-screens look or macOS's wash-out on the active screen. Check real screenshots of the active
  screen and the other screens, in Light and Dark.
- Refresh/sleep/power behaviour: perform the action, then read the persisted logs.
- Say plainly what was and wasn't verified on real hardware.

## Contributing

- Visual changes: propose concrete options (a temporary picker works well), compare them on real
  menu bars, then remove the options that lose.
- Record new decisions and measurements in `docs/DECISIONS.md` with the evidence.
