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
- Push-to-talk release resolves unknown → **muted** (`pushToTalkRestoreTarget`),
  cancels any in-flight key-down work, and watches for an unmute that lands late.

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
- **A meeting is a separate `AXWindow` of the same pid.** Normally it is
  identified by `hangup-button`; while sharing full-screen, Teams replaces it
  with a presenter window identified by the combination of
  `microphone-button` + `video-button` + `share-button`.
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

### Ten gotchas that will bite you

1. **WebView2 can expose only empty groups until explicitly awakened.** The
   native meeting window remains present, but every control is absent and all
   hotkeys fail honestly with `presses=0`. Call
   `AX.prepareWebAccessibility(ofPID:)` before discovery; `MeetingWorker` retries
   on consecutive non-blocking poll ticks while the tree materialises. The
   WebView2 setters may return unsupported/not-implemented while still producing
   the required side effect.
2. **Full-screen sharing removes the hang-up control.** The presenter window
   still exposes mic, camera, and share buttons, but no `hangup-button`. Treat
   that three-control combination as a meeting window; requiring only mic would
   match the duplicate in Teams' main window.
3. **Modal dialogs blank the tree.** Teams' "Invite people" popup is
   `aria-modal`, so while it's open the rest of the meeting UI is absent. A
   discovery failure is never treated as "meeting ended" without retries.
4. **`microphone-button` is not unique** — the main window has one too, and
   mid-toggle the two disagree. Always scope lookups to the meeting window.
5. **References go stale on re-render.** Detect `kAXErrorInvalidUIElement` and
   re-find — but that alone is NOT enough (see 6).
6. **The meeting window's subrole varies, and swaps detach elements silently.**
   Full meeting window is `AXStandardWindow`; the **compact view** is an
   `AXSystemDialog`. Teams swaps between them as you navigate, and orphaned
   elements keep answering reads with their *last-known* label rather than
   returning `kAXErrorInvalidUIElement`. A stale label is worse than a dead
   reference: `Actuator.toggle` reads state to pick a direction, so it presses
   the wrong way and can leave you live when you asked to be muted. Hence
   `cachedWindowIsCurrent()` — verify the window is still in Teams' live window
   list, not just that the element hasn't been invalidated.
7. **Exiting full-screen is a window swap wrapped in a macOS animation you
   don't control.** The Space-transition alone runs ~0.5–1 s before Teams even
   tears down the presenter window and rebuilds the normal one — longer than
   the display-side "no meeting" grace period once was (0.6 s), so the
   two-glyph menu bar icon briefly collapsed to one glyph mid-transition. It
   went unnoticed on full-screen *entry* only because full screen hides the
   menu bar there. `Tuning.missesBeforeIdle` / `rediscoveryBurst` (3.0 s) cover
   this now; a `MEETING-FLICKER` line in the diagnostic log (only written if
   the glyph actually visibly flickers) records how long any future gap runs.
8. **A cached element can be repurposed, not just invalidated — hardened
   against, not yet reproduced.** Gotcha 6 already established that Teams
   leaves detached elements answering with a stale label instead of erroring.
   WebView2/Chromium is also known to recycle accessibility node objects
   across re-renders, which would let a cached "mic" reference silently start
   representing a different control (e.g. camera) while still passing every
   guard above (`isStale` false, window still current). `TeamsAXClient` now
   also records the DOM id each control was discovered under and re-checks it
   before every press or read, treating a mismatch like staleness. This was
   added defensively after a reported (but unreproduced) case of a mic hotkey
   appearing to also flip the camera; there is no confirmed measurement behind
   it the way the other gotchas have, so treat it as a hardening, not a fact.
9. **A minimized meeting window can still be the only one with controls, and
   pressing through it may not actually take — strong evidence, not yet
   airtight proof.** Reported scenario: the Teams main window is on another
   Space, its compact "mini" window is minimized, and a mic-unmute hotkey
   reads back as succeeded but the mic is allegedly still muted in the real
   meeting. A read-only probe against a live meeting confirmed the setup —
   the main window currently exposes zero known controls, so the minimized
   compact window is necessarily the one `locateMeetingWindow` selects; there
   is no other live control being ignored. This is not a Spaces/Accessibility
   limitation: `kAXWindowsAttribute` returns every one of Teams' windows
   regardless of which Space it's on, and CoughButton enumerates the main
   window every poll tick (it's the `AXStandardWindow` in the `windows=[...]`
   diagnostics). A follow-up probe confirmed *why* it has no controls: its
   WebView2 tree is fully alive (757 real accessibility nodes, not the empty
   groups gotcha 1 describes), and re-issuing the same wake-up hint
   `refresh()` already calls made no difference — none of the five known
   control DOM ids exist anywhere in that tree. Teams evidently hosts the
   meeting toolbar in only one place at a time; once it's popped out into the
   separate mini window, the main window's own DOM simply doesn't contain
   those controls, independent of Space or minimized state. So there is no
   alternate, better window CoughButton could have chosen instead — the mini
   window is the only place the controls exist, full stop. Whether pressing
   through it while *minimized specifically* is what causes a press not to
   take is the part that remains unconfirmed. On reproduction (2026-08-20
   17:24), the log recorded `ACTUATED-VIA-MINIMIZED-WINDOW toggleMic ...
   observed=on`; a follow-up read-only probe roughly two minutes later, with
   zero further presses logged in between, found the same control's own
   label back to `"Unmute mic"` (muted) — the control reverted with nothing
   in CoughButton touching it. That is close to conclusive for "the press
   didn't really take, or Teams reverted it," but not fully: it can't rule
   out the user muting again through Teams' own UI in that window, which
   would look identical from the outside. Chromium's Page Visibility
   throttling affects timers and `rAF`, not synchronous click dispatch,
   which weakens but doesn't rule out a suspended-renderer explanation
   either. No actuation behaviour has been changed on the strength of this —
   pressing through a minimized window is not yet refused, since doing so
   would break a seemingly common and otherwise-working usage pattern (main
   window on another Space, mini window minimized) on the strength of one
   incident. Observability was extended instead: `MeetingClient.isActingWindowMinimized`
   plus two diagnostic lines — `ACTUATED-VIA-MINIMIZED-WINDOW` (toggles only,
   not push-to-talk) when a press through a minimized window is verified as
   succeeded, and `REVERTED-AFTER-MINIMIZED-ACTUATION` if that same control's
   state changes away from what was believed with no further CoughButton
   action recorded in between. **Reproduced a second time** (2026-08-20,
   ~18:07): a mute logged `ACTUATED-VIA-MINIMIZED-WINDOW toggleMic ...
   observed=off`, and roughly ten minutes later — again zero further
   CoughButton actions logged — a manual probe read the same control back as
   unmuted. Both real occurrences (~2 min, then ~10 min) blew straight
   through the diagnostic's original 30-second watch window, so
   `revertWatchWindow` was widened to 15 minutes; the *next* occurrence should
   now produce both log lines back to back automatically. Neither occurrence
   rules out the user (or another device) manually re-toggling through
   Teams' own UI in between — that ambiguity still stands — but two
   independent reproductions, in opposite directions, both while acting
   through a minimized window and nothing else, is stronger evidence than
   one. Given that ambiguity, refusing to actuate through a minimized window
   was rejected (it would break what looks like a normal daily setup — main
   window on another Space, mini window minimized — on the strength of two
   still-ambiguous data points) in favour of a cheap, reversible, purely
   additive nudge: `RevertNotifier.swift`'s `SystemRevertNotifier` posts a
   one-time-authorized `UNUserNotificationCenter` alert whenever
   `REVERTED-AFTER-MINIMIZED-ACTUATION` fires, naming the control and what it
   reverted to. It changes nothing about actuation or the live glyph — the
   glyph is already re-read fresh every poll tick and was never wrong in the
   moment — it only makes the *retrospective* "a past success report may have
   been wrong" case visible to the user instead of living only in the log
   file. It inherits the same false-positive risk as the underlying
   detector: a legitimate manual re-toggle via Teams' own UI inside the
   15-minute belief window would also trigger it.
10. **A window in native macOS fullscreen on an inactive Space is completely
    invisible to `kAXWindowsAttribute` — confirmed, and there is no public-API
    fix.** This is different from gotcha 9: an ordinary windowed Teams window
    parked on another regular desktop Space enumerates fine (proved earlier by
    walking its full 757-node tree). A window in *native* fullscreen is
    different — macOS gives it its own dedicated Space, and while that Space
    isn't the active one, `AXUIElementCreateApplication(pid)` →
    `kAXWindowsAttribute` silently omits it, even though the window is
    genuinely still there. Confirmed live: `CGWindowListCopyWindowInfo`
    reported a real "Meeting with ..." window (id 6211, bounds 1710×1073,
    `onscreen=false`) that `kAXWindowsAttribute` never returned in the same
    instant — while Xcode's Accessibility Inspector *could* read
    `microphone-button` on it, because the user had switched to that Space to
    point Inspector at it, which is the one condition that makes it visible.
    This is documented, expected macOS behaviour with no public workaround
    (see `alt-tab-macos#14`) — window switchers hit the exact same wall.
    Private APIs (e.g. `CGSCopyManagedDisplaySpaces`) could theoretically see
    more, but they're unsupported, break across OS versions, and would still
    need a *different* private API to get a pressable `AXUIElement` for a
    window AX itself refuses to enumerate — not something to take on for this
    project's zero-dependency, stability-first bar without a much stronger
    case than one report. Practical fallout: if the compact "mini" window is
    open (even minimized — minimization doesn't hide its tree, only the
    fullscreen-Space exclusion does), hotkeys keep working through it per
    gotcha 9's fallback. If the mini window is closed and the *only* meeting
    controls live in a fullscreen window on a Space you've since switched away
    from, CoughButton finds zero controls anywhere and correctly reports
    unknown/fails rather than lying — but this is very likely the real
    explanation for the earlier "full-screen sharing breaks the hotkeys"
    report: whichever Space you're actively looking at (e.g. the shared
    content, if it's also fullscreen) is what matters, not "sharing" per se.

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
