# Burnbar: decision log

Why Burnbar is built the way it is: what was tried, what was measured, and what was decided.
Built and tuned in November 2026 on macOS 27.2 (Apple Silicon, three displays: one built-in and two
external), Swift 6.4, Command Line Tools only (no Xcode).

Read this before changing the menu bar item's look, the colours, the refresh policy or the data
source. Several "obvious" fixes were tried and failed for reasons that only show on a real menu bar;
they are recorded here so they aren't tried again.

---

## 1. Data source

| Decision | Why / evidence |
|---|---|
| `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20` | Verified with a live call (HTTP 200) in November 2026. A trimmed sample with the same structure is the test fixture `Tests/BurnbarCoreTests/Fixtures/usage-sample.json`. |
| Parse both `five_hour` / `seven_day` objects **and** the `limits[]` array | In the live response `seven_day_opus` / `seven_day_sonnet` were null and the per-model weekly limit appeared only in `limits[]` as `kind: "weekly_scoped"`. The API is undocumented, so it is parsed defensively (numbers or numeric strings, booleans rejected, values clamped). |
| Show "Weekly limit used by" (Claude Code / Cowork / Chats) | Present in the live response as `seven_day_breakdown.rows[].percent_of_limit`. |
| Round every `resets_at` to the minute | Two calls 20 s apart returned `17:39:59.548` and `17:40:00.225` for the same window. Rounding keeps countdowns stable and lets stored samples be matched to a window (±2 min tolerance). |
| Token from Keychain item `Claude Code-credentials` → `claudeAiOauth.accessToken`, `expiresAt` (ms) | The structure Claude Code stores. The access token lives about 8 h. |
| **Strictly read-only.** Never refresh or write the token | A refresh rotates the refresh token and would sign Claude Code out. When the token has expired, Burnbar shows "run `claude`" and does not call the API; it picks up the new token on its next check. (Running `claude auth status` was observed to make the CLI refresh its own token.) |
| Read the Keychain with `/usr/bin/security find-generic-password -w`, not `SecItemCopyMatching` | Claude Code created the item with `security`, so that binary is on the item's access list: no permission prompt, and no re-prompt after every rebuild (ad-hoc signatures change each build). A 10 s watchdog stops a stuck prompt from hanging a fetch. |
| 401/403 → signed-out state; Keychain errors → also signed-out (normal interval) | An invalid token was confirmed to return 401. Keychain errors (denied prompt, locked keychain) aren't transient, so they must not take the fast-retry path (found in code review). |
| 429 → back off `max(Retry-After, 60 s × 2ⁿ)`, capped at 30 min; Retry-After clamped to 1 h | Code review found that a small Retry-After after a network failure could otherwise retry every 30 s indefinitely. |

## 2. Refresh policy

- On power 5 min (2 min if session ≥ 80 %); on battery 15 min (5 min if ≥ 80 %). Weekly usage never
  affects the interval.
- Paused while asleep, screen-locked, or the user session is switched out; fetch ~3 s after
  wake/unlock. A pending wake fetch isn't pushed back by a power-source change (code review).
- Fetch once ~10 s after a reset time passes. Timers carry 10 % tolerance (≤ 60 s). Countdowns
  redraw on minute boundaries with no network.
- Failed fetch: keep values, grey them out, show the real age. Transient failures retry at 30 s,
  1, 2, 4 min (capped at the interval).
- **Verified on real hardware** (from persisted logs): unplugging moved the interval from 300 to
  900 s and the next fetch to last + 15 min; replugging restored 300 s; lock/unlock and sleep/wake
  paused and resumed with one fetch 3–4 s later; idle display sleep paused.
- **Not verified live:** the post-reset fetch, a real 429, the 2-minute interval at ≥ 80 %, and
  greying after a real failed fetch.
- Logging is at `.notice` level: `.info` messages are kept in memory only and were lost before they
  could be read.

## 3. Colour logic

- **Session (S):** green < 50 %, amber 50–80 %, red ≥ 80 %.
- **Week (W):** by *pace*, usage projected to the reset at the **average rate since the week
  began**: green < 80 %, amber 80–100 %, red ≥ 100 % or ≥ 95 % used. The since-reset average is used
  because a week includes nights and weekends. For the first 12 h after a reset, the session
  thresholds apply to the raw %.
- **"At this rate you'll hit the limit ~Fri 9 PM":** shown only if the forecast lands before the
  reset. The rate comes from stored samples (last 1 h for session, 6 h for week), falling back to
  the since-reset average until enough samples exist. Samples are kept 48 h in
  `~/Library/Application Support/Burnbar/samples.json`.
- The 80 / 100 % pace thresholds are an initial choice and haven't been tuned against real use.

## 4. Countdown format

Notion style: `2 h 2 m`, `1 d 13 h`, `42 m`. A narrow no-break space (U+202F) joins each number to
its unit, a normal space separates components, no zero-padding. Under a day, minutes appear; from a
day up, hours are the smallest unit. The same format is used in the menu bar and the dropdown.

## 5. How macOS 27 draws a menu bar item (measured; drives §6–7)

These were established by experiment and are why the drawing code looks the way it does.

1. **The item is drawn once per display.** A per-pass log showed separate drawing passes per screen.
2. **Every pass uses a *dark* appearance, even in Light mode.** Logged passes were `DarkAqua` and
   `VibrantDark` (with occasional `Aqua` / `VibrantLight`), never reliably matching the bar's real
   look. So a view's `effectiveAppearance` can't tell light from dark. **The theme comes from
   `NSApp.effectiveAppearance` (the system Light/Dark setting).** An earlier version used the view's
   appearance and drew dark-mode colours in Light mode.
3. **Colour-per-pass test:** each appearance was painted a different colour and all three screens
   were photographed. The **active screen** always showed the **VibrantDark** pass; **other
   screens** always showed the **DarkAqua** pass; the Aqua pass was never visible. So
   `NSAppearance.currentDrawing()` being vibrant means "drawing for the active screen", which is how
   per-screen colours work. This is undocumented behaviour and could change in a future macOS.
4. **The active screen washes out coloured content on light menu bars.** Three drawing methods were
   compared side by side in the same dark green: a custom view, a non-template `NSImage` in
   `button.image` (the most washed out, nearly invisible), and a coloured `attributedTitle`. All
   washed out, so the method doesn't matter; the fix had to be the colours plus a backdrop: the pill.
5. **macOS draws its own click highlight over the whole item, and it can't be turned off.**
   `(button.cell as? NSButtonCell)?.highlightsBy = []` had no effect on macOS 27.
6. **The slot (status item length) is one width for every screen.** The active screen lets drawing
   extend past the slot into the highlight's padding (the button doesn't clip; `clipsToBounds =
   false`); **other screens clip drawing at the slot's edges.**
7. The status item measured **22 pt** tall (`NSStatusBar.system.thickness` 22; the main screen's
   menu bar itself was 30 pt).
8. Offscreen renders (`Burnbar --snapshot`) always draw as the active screen and can't show the
   wash-out, so real menu bar checks need real screenshots of each screen.

## 6. Menu bar item design (in order)

1. The original brief asked for two switchable styles: a background pill or coloured text.
2. A temporary picker (4 backgrounds × 4 palettes) was used to compare options live on real bars.
3. **One design for both themes** was chosen over separate light and dark designs, for
   consistency: **a single pill behind the whole item.** The picker was then removed.
4. **Layout rules** (implemented in `StatusView.swift`):
   1. 8 pt horizontal padding, 3 pt vertical, measured to what is *visible*. The flame image has
      16 % empty space on each side (its ink spans x 16…84 of 100), so its frame is offset to match.
   2. Equal spacing between flame, S, divider and W: 6 pt gaps. The divider is a drawn 1 pt line;
      a "│" character with spaces had uneven side bearings.
   3. Full capsule: corner radius = half the height.
   4. Text centred on its cap height (not its line box); the flame centred too.
   5. Some breathing room from neighbouring menu bar items.
   6. The selected (menu open) state consistent with the normal state; see width, below.
   7. Width follows the text, recomputed on every render.
   With a 22 pt item and 3 pt vertical padding the flame is 16 pt (18 pt is the cap).
5. **Selected-state width.** Since the highlight can't be disabled, the pill is drawn past the slot
   so the highlight hugs it. A slider from −6 to +6 pt was tried: at 0 a visible ring remained; −4
   merged pill and highlight but crowded the neighbouring item and made the open state hard to see
   on a light pill; **−3 was chosen** (a thin, even ring when open). Implemented as slot = pill −
   3 pt each side (`overhang = 3`).
6. **Other screens chopped the pill's ends at −3**, because they clip at the slot. Fix: on
   other-screen passes the pill is drawn *inside* the slot (as at 0 pt). To keep the ends from
   looking tight, the inner gaps shrink from 6 to 5 pt there and the content is re-centred (about
   6.5 pt of end padding). The slider was removed once −3 was settled.
7. When the menu is open, the pill is also drawn slightly darker (its own pressed state) under
   macOS's highlight.
8. **Flame ("Ember gauge"):** the outline is always visible and the inside fills from the bottom to
   the session %: clip `y = 94 − 0.88 × session%` in the 100×100 SVG space. Originally a template
   image tinted by macOS; now drawn in the pill's colours so the **fill follows the session's
   green, amber or red**. Dimmed to 45 % when data is stale.

## 7. Colours

All are built-in defaults in `Palette.swift` (`ColourSlot.builtInHex` / `builtInInactiveHex`),
tuned colour by colour on real screens.

**Active screen in Light and Dark, and other screens in Dark:**

| Background | Border | Divider | Green | Amber | Red | Flame outline | Flame fill |
|---|---|---|---|---|---|---|---|
| `#253746` | `#435A6B` | `#8093A0` | `#55D68A` | `#FFC04D` | `#FF7070` | `#DCE4E8` | session colour |

**Other screens in Light:**

| Background | Border | Divider | Green | Amber | Red | Flame outline | Flame fill |
|---|---|---|---|---|---|---|---|
| `#000000` | `#52616D` | `#8196A7` | `#087C48` | `#A66A00` | `#C94A4A` | `#FFFFFF` | session colour |

- How it got there: a "Standard" palette on a translucent chip, then a series of slate backgrounds,
  then the tables above. Other screens in Light mode render the item differently (§5), so they got
  their own set.
- The stale grey switches between light and dark to suit the background's brightness.
- **"Customise Appearance…" (⌘,) was kept deliberately** so anyone can retune for their own
  wallpaper and displays. Hex per theme and per screen kind; a blank other-screens field uses the
  built-in other-screens colour where one exists, else the active-screen colour; a blank active
  field uses the built-in colour. Stored as `colour.<day|night>[.inactive].<slot>` in
  `com.burnbar.Burnbar` preferences. "Reset All to Defaults" restores the tables above.
- **The dropdown keeps its own light/dark colours** (light: `#1A7F37` / `#B35C00` / `#CF222E`;
  dark: `#3FD467` / `#FFC23D` / `#FF6B61`) because the bar's colours are tuned for a dark pill
  (amber `#FFC04D` is unreadable on a light menu).

## 8. Dropdown

- A SwiftUI panel (300 pt wide) inside the `NSMenu`: session and week gauges, exact reset times, a
  pace line with an even-pace tick on the week bar, the warning line, other weekly limits, usage by
  surface, and last updated / next check / on battery.
- The week bar used to be thicker than the session bar because the 10 pt even-pace tick stretched
  it; the bars are pinned to 6 pt and the tick is an overlay.
- The "Notify Near Limits" hint is a small subtitle (macOS 14.4+) rather than part of the title,
  which had set the whole menu's width.
- Usage-by-surface groups use non-breaking spaces so "Claude Code 13%" never splits across lines.
- Notifications fire at 80 % and 95 % (session and week), once per window. If the permission prompt
  is dismissed, macOS records it as denied; enable Burnbar in System Settings › Notifications.
- Launch at Login is registered once, on the installed app's first run (`SMAppService`).

## 9. App icon

The static "Ember gauge" design, placed on Apple's icon grid (824 px body on a 1024 px canvas),
rendered by `Burnbar --render-icon` and packed with `iconutil` in `install.sh`. macOS 26+ may show
it inside a grey rounded square because it isn't made with Icon Composer (which needs Xcode).

## 10. Engineering choices

- No third-party dependencies. Swift tools version 6.4 (what `swift package init` writes for that
  toolchain), Swift 6 strict concurrency. Minimum macOS 14 (originally for
  `NSMenuItem.sectionHeader`).
- `BurnbarCore` (pure logic, unit-tested: parsing, pace, forecast, formatting) is separate from
  the AppKit app. The suite was checked by deliberately breaking the weekly colour logic and
  confirming a test failed.
- Ad-hoc signed and installed to `~/Applications`. `install.sh` retries `open` once because
  LaunchServices returned error -600 right after the old copy quit.
- Distribution: a Mac App Store build looks infeasible, because the required App Sandbox blocks
  reading another app's Keychain item. A Developer ID–signed, notarised download would work; it
  hasn't been set up. Neither conclusion was checked against current Apple or Anthropic
  documentation.

## 11. Known gaps

Not verified on real hardware or live: the post-reset fetch, a real HTTP 429, the 2-minute interval
at ≥ 80 %, greying after a real failed fetch, notification delivery, and the end padding of the
other-screens pill after the gap change in §6.6.
