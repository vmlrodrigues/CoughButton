# Changelog

All notable changes to CoughButton are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- 66 unit tests covering the label→state inversion, actuation and retry logic,
  push-to-talk restore policy, shortcut normalisation and settings persistence.

### Notes

- Every action is press-then-verify. CoughButton never reports a state it has
  not confirmed — the failure mode this app exists to prevent is believing you
  are muted while you are live.
- Control identification uses Teams' stable DOM ids
  (`microphone-button`, `video-button`, `raisehands-button`), which are
  locale-independent. State reading uses the English label verbs, which are not;
  on a non-English Teams the controls work but the indicator reads "unknown".

[Unreleased]: https://github.com/vmlrodrigues/CoughButton/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/vmlrodrigues/CoughButton/releases/tag/v0.1.0
