# Changelog

All notable changes to CoughButton are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Two quiet diagnostic lines for a mic/camera toggle acted through a
  minimized Teams window: `ACTUATED-VIA-MINIMIZED-WINDOW` when such a press
  is verified as succeeded, and `REVERTED-AFTER-MINIMIZED-ACTUATION` if that
  same control's state changes away from what was believed with no further
  hotkey action in between. Reproduced twice (2026-08-20): a mic toggle
  logged as succeeded, then read back in the opposite state roughly two
  minutes later (first occurrence) and again roughly ten minutes later
  (second occurrence), both times with nothing else touching it — strong
  evidence the press didn't actually take effect, though not fully
  conclusive (a manual re-toggle through Teams' own UI would look identical
  from the outside). Both real occurrences exceeded the diagnostic's
  original 30-second watch window, so it was widened to 15 minutes. No
  actuation behaviour changed on the strength of this; pressing through a
  minimized window is not refused, since doing so would break what looks
  like a common, otherwise-working usage pattern. See gotcha 9 ("Ten
  gotchas that will bite you") in `CLAUDE.md`.
- Documented (no code change) why an off-Space Teams window can have zero
  usable meeting controls even though its accessibility tree is fully
  populated: Teams only hosts the meeting toolbar in one window at a time,
  so once a meeting is popped into the separate compact "mini" window, the
  main window's DOM simply never contains those controls, regardless of
  Space or minimized state. See gotcha 9 in `CLAUDE.md`.
- Documented (no code change) a genuine macOS Accessibility limitation: a
  window in native fullscreen on an inactive Space is invisible to
  `kAXWindowsAttribute` even though it still exists at the WindowServer
  level — confirmed live and against known platform behaviour, with no
  public-API workaround. Likely the real explanation for an earlier report
  that hotkeys stop working while sharing full-screen. See gotcha 10 in
  `CLAUDE.md`.

## [0.2.1] — 2026-08-19

### Fixed

- Stopped the camera glyph from momentarily vanishing from the menu bar when
  exiting Teams full-screen back to the main screen. The menu bar's own
  "no meeting" grace period (previously 0.6 s) was shorter than macOS's own
  full-screen exit animation, so the two-glyph meeting display briefly
  collapsed to one glyph while Teams rebuilt its window. Widened the grace
  period so it comfortably covers that transition.
- Added a quiet, permanent diagnostic line (only written if the glyph actually
  visibly flickers) recording how long a meeting was briefly lost, to make any
  future recurrence immediately measurable instead of anecdotal.
- Hardened control identity: a cached mic/camera/hand reference is now
  re-verified against the DOM id it was discovered under before every press or
  read, not just checked for staleness. WebView2 can recycle an accessibility
  node to represent a different control after a re-render without ever
  invalidating the reference, which previously could have let a hotkey act on
  the wrong control with no error reported.

## [0.2.0] — 2026-08-13

### Fixed

- Restored hotkeys when Teams' WebView2 Accessibility tree goes dormant by
  explicitly activating web accessibility and retrying discovery while the
  controls materialise.
- Kept actions reliable through fullscreen, minimise/restore, and compact-view
  transitions by allowing bounded time for delivery and verification while
  retaining a strict two-press maximum.
- Made push-to-talk key-up cancel in-flight key-down work and continue watching
  for a delayed unmute, re-muting it if it lands after the key is released.
- Rejected detached meeting-window references that continue returning stale
  labels after Teams replaces a full or compact meeting window.
- Recognised Teams' full-screen presenter window while sharing an entire screen,
  where mic, camera, and share controls remain available but the normal hang-up
  control is absent.
- Added privacy-safe diagnostics for unverified actions, recording control and
  window shape without meeting titles or other identifying content.

## [0.1.0] — 2026-08-07

First release.

### Added

- Global hotkeys for **mute/unmute**, **camera on/off** and **raise/lower hand**,
  working while Teams is in the background.
- **Push-to-talk** (hold to talk) — the cough button proper. Releasing restores
  the mic to its prior state, and ends muted if that state was unreadable.
- Menu-bar indicator showing live mic and camera state: red for transmitting,
  grey for off, orange when the state cannot be confirmed.
- Settings window with rebindable shortcuts, a hand-rolled shortcut recorder
  (Delete unbinds, Escape cancels, bare keys refused), conflict detection, and
  a Start-at-Login toggle.
- Silent auto-update from GitHub Releases, gated to Developer ID builds and
  verifying signing team + Gatekeeper before installing.
- 78 unit tests covering the label→state inversion, actuation and retry logic,
  the poll loop's re-discovery tolerances, push-to-talk restore policy,
  shortcut normalisation and settings persistence.

### Notes

- Every action is press-then-verify. CoughButton never reports a state it has
  not confirmed — the failure mode this app exists to prevent is believing you
  are muted while you are live.
- Control identification uses Teams' stable DOM ids
  (`microphone-button`, `video-button`, `raisehands-button`), which are
  locale-independent. State reading uses the English label verbs, which are not;
  on a non-English Teams the controls work but the indicator reads "unknown".

[Unreleased]: https://github.com/vmlrodrigues/CoughButton/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/vmlrodrigues/CoughButton/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/vmlrodrigues/CoughButton/releases/tag/v0.1.0
