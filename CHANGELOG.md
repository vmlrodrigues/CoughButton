# Changelog

All notable changes to CoughButton are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
