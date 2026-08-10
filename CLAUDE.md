# CoughButton

A macOS **menu-bar app** (Swift / SwiftUI, SwiftPM, no Xcode project) giving
global hotkeys for mic, camera, raise-hand and push-to-talk in Microsoft Teams,
after Microsoft retired the local third-party API that mute apps relied on.

It drives Teams' own on-screen controls through the **Accessibility API**. No
dependencies, no injection, no network except the GitHub updater.

## Build / run / verify

```sh
make local     # swift build -c release + assemble CoughButton.app
make run       # launch it
make test      # unit tests (forces DEVELOPER_DIR — XCTest needs full Xcode)
swift build    # quick compile check
```

**Headless mode — use it before judging any menu-bar glyph change:**

```sh
.build/release/CoughButton --render-status-icons /tmp
```

Writes `status-icons.png`: every state, on simulated light and dark menu bars,
at actual size and 4×. Template images are tinted the way macOS would tint them,
so the sheet reflects reality. Judging a 16pt glyph by squinting at one state in
the real menu bar is how the first version shipped looking bad.

`xcode-select` on this machine points at the Command Line Tools, which have no
XCTest. `make test` works around that by setting `DEVELOPER_DIR` for that one
command — don't "fix" it by requiring a `sudo xcode-select -s`.

## The core invariant

**Never show or report a state that hasn't been verified.** The failure this app
exists to prevent is believing you're muted while you're live. Concretely:

- Every action goes through `Actuator`, which presses and then re-reads, retries
  once against a freshly-discovered element, and reports failure rather than
  assuming success.
- `ToggleState.unknown` is a first-class value that reaches the UI as an orange
  glyph. Do not "helpfully" collapse it to `.off`.
- Push-to-talk release resolves unknown → **muted** (`pushToTalkRestoreTarget`).

## The label inversion — read this before touching ControlLabels

Teams labels a control with the action it *offers*, so every reading inverts:
`"Unmute mic"` means you are currently **muted**.

**`"unmute"` contains `"mute"` as a substring.** The negated form must be tested
first or every muted mic reads as live — exactly inverted, in the dangerous
direction. Same for `"camera off"` before `"camera on"`. `ControlLabelsTests`
covers this; if you refactor the matching, keep those tests passing.

## Teams facts (verified 7 Aug 2026, build 26198.202.4929.7171)

Established by measurement, not documentation — see FINDINGS.md and `probe/`.

- Teams' WebView2 exposes the **full web accessibility tree**.
- Meeting controls have stable, locale-independent DOM ids:
  `microphone-button`, `video-button`, `raisehands-button`, `hangup-button`.
- **`AXPress` works on a background window and does not steal focus** (0 ms).
  No synthesised keystrokes are needed — an early focus-steal was Teams' own
  *navigation* handler, not the press mechanism.
- **A meeting is a separate `AXWindow` of the same pid.** That's the
  "in a meeting" signal.
- Cached-reference read ≈ **0.017 ms**; full tree walk 70–200 ms. Hence:
  discover once, cache, poll at 10 Hz.
- **There is no boolean state attribute — settled, don't re-investigate.** All 45
  attributes of the in-meeting `microphone-button` were enumerated live
  (`axctl attrs`). `AXValue` is empty, `AXSubrole` unsupported, `AXSelected`
  stays `0` across a toggle. **`AXDescription` is the only attribute that
  changes.** Teams uses real toggle semantics elsewhere (app-bar tabs, and the
  *pre-join* mic is an `AXSwitch` with a value) — but not in-meeting, so the
  pre-join screen is not a valid stand-in. Locale independence has to come from
  outside the tree: calibrate the labels against a CoreAudio mic-in-use signal.
- `AXKeyShortcutsValue` exposes each control's current Teams shortcut
  (`⇧ ⌘ M`), language-independently and reflecting user remapping — a useful
  fallback for identifying controls if the DOM ids change.

### Three gotchas that will bite you

1. **Modal dialogs blank the tree.** Teams' "Invite people" popup is
   `aria-modal`, so while it's open the rest of the meeting UI is absent. A
   discovery failure is never treated as "meeting ended" without retries.
2. **`microphone-button` is not unique** — the main window has one too, and
   mid-toggle the two disagree. Always scope lookups to the meeting window.
3. **References go stale on re-render.** Detect `kAXErrorInvalidUIElement` and
   re-find — but that alone is NOT enough (see 4).
4. **The meeting window's subrole varies, and swaps detach elements silently.**
   Full meeting window is `AXStandardWindow`; the **compact view** is an
   `AXSystemDialog`. Teams swaps between them as you navigate, and orphaned
   elements keep answering reads with their *last-known* label rather than
   returning `kAXErrorInvalidUIElement`. A stale label is worse than a dead
   reference: `Actuator.toggle` reads state to pick a direction, so it presses
   the wrong way and can leave you live when you asked to be muted. Hence
   `cachedWindowIsCurrent()` — verify the window is still in Teams' live window
   list, not just that the element hasn't been invalidated.

## Architecture

```
Sources/CoughButton/
  CoughButtonApp.swift   @main struct with a @MainActor main(). NOT main.swift —
                         top-level code isn't main-actor isolated, which breaks
                         every AppKit call.
Sources/CoughButtonKit/
  AX.swift               thin non-throwing wrapper over the C Accessibility API
  MeetingClient.swift    MeetingClient protocol + ControlLabels (the inversion)
  TeamsAXClient.swift    the Teams adapter — DOM ids, meeting-window scoping
  Actuator.swift         press-then-verify, retry, honest failure. Injectable wait
  MeetingController.swift @MainActor published state + queue-confined MeetingWorker
  HotkeyEngine.swift     CGEventTap (key-up is why, not RegisterEventHotKey)
  Shortcut.swift         chord value type, normalisation, ⌃⌥⇧⌘ display
  Settings.swift         HotkeyAction + UserDefaults-backed store + conflicts
  ShortcutRecorder.swift NSView recorder + SwiftUI wrapper
  SettingsView.swift     SwiftUI settings + window controller
  StatusIcon.swift       menu-bar glyph rendering
  StatusItemController.swift  NSStatusItem + menu
  Updater.swift          GitHub-Releases self-updater (ported from BarPilot)
  LoginItem.swift        SMAppService "Start at Login"
tools/icon-gen.swift     draws the app icon; `make icons` regenerates AppIcon.png
probe/                   the AX investigation tools (axdump, axctl, …) — still useful
```

## Design decisions — don't casually revert these

- **AppKit `NSStatusItem`, NOT SwiftUI `MenuBarExtra`** — MenuBarExtra is
  unreliable in a hand-assembled SwiftPM bundle (same call as BarPilot). The
  settings UI is still SwiftUI, hosted in an NSWindow.
- **`CGEventTap`, not `RegisterEventHotKey`** — push-to-talk needs key-*up*,
  which Carbon doesn't deliver. Accessibility permission is already required, so
  the tap costs nothing extra.
- **Key-up is matched on key code ALONE**, not the full chord. Releasing
  ⌃⌥⌘Space usually lifts a modifier first, so re-matching the chord would strand
  push-to-talk held and leave the mic open.
- **Auto-update is the built-in GitHub-Releases updater, NOT Sparkle** — ported
  from BarPilot, where Sparkle was rejected as too heavy for a hand-assembled
  bundle (embedded framework + XPC services + nested signing + appcast).
  Re-confirmed for this project.
- **Zero third-party dependencies**, including the shortcut recorder. Deliberate:
  it keeps the bundle a single binary and the supply-chain surface nil.
- **The tap is suspended while recording a shortcut** (`HotkeyEngine.isSuspended`)
  or rebinding ⌃⌥⌘M would also fire mute.
- **Local builds are signed with the Developer ID cert, not ad-hoc.** macOS binds
  an ad-hoc app's TCC grant to that build's *cdhash*, so every rebuild looked
  like a new app and silently lost Accessibility permission. Because of that the
  updater can no longer infer "dev build" from the signature — `build-app.sh`
  stamps a `CBDevBuild` flag into Info.plist for anything that isn't
  `make release`. Don't remove one without the other.

### Menu-bar glyph rules (StatusIcon)

1. The resting state (muted, camera off) renders as a **true template image**,
   so macOS tints it like every other menu-bar icon across light/dark, menu-open
   and reduced-transparency. An NSImage is template or not — there is no partial
   mixing, so as soon as anything needs colour the rest falls back to
   `labelColor`.
2. **Colour means danger only.** Red = transmitting, orange = unconfirmed.
   Nothing else gets a colour — that's why a raised hand is monochrome.
3. **Shape stays stable.** "Unknown" is the same mic in an orange outline, never
   a question mark; an icon that morphs into a different symbol is unreadable at
   a glance and looks broken.
4. **Glyph count carries meeting presence** — one glyph = no meeting, two = in a
   meeting — so the icon never jitters width to convey something shape can.
5. Off states use **outline** variants: `video.slash.fill` is a solid rectangle
   that optically swamps the mic next to it.

## Testing

`Tests/CoughButtonKitTests` — 78 tests, no Teams required. `FakeMeetingClient`
models the cases that actually bite: presses that are accepted but don't take
(stale element), presses that can't be delivered, and unreadable state. Keep
`Actuator`'s `wait` injectable so retry logic runs at full speed.

The UI seam is deliberate: anything worth testing lives behind `MeetingClient`
or in a pure function. Prefer adding logic there over in a view.

## Release checklist

Before `make release VERSION=x.y.z`:
1. Update `VERSION`.
2. Update `CHANGELOG.md` — promote `[Unreleased]` to `[x.y.z] — YYYY-MM-DD` and
   add a fresh `[Unreleased]`.
3. Commit, merge to `main`, then release.

See DISTRIBUTION.md for signing/notarisation setup. The repo is **public** —
keep usernames, local paths and emails out of issues.
