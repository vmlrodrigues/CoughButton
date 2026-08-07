# CoughButton

Global hotkeys for your microphone, camera and raised hand in **Microsoft
Teams** — working while Teams is in the background, and showing you the real
state in your menu bar.

> A *cough button* is a broadcast term: the button a radio presenter holds to
> kill their own mic while they cough. That is exactly this app's job.

A macOS menu-bar app. No Dock icon, no window in your way, no dependencies.

---

## Why this exists

Microsoft **permanently retired** the Teams local third-party API — the
WebSocket on `127.0.0.1:8124` that mute buttons and hardware relied on
(notice MC1266901, effective 30 June 2026). The Settings ▸ Privacy ▸
"Third-party app API" toggle is gone, there is no replacement, and no admin
setting brings it back. Stream Deck, MuteDeck, MuteMe, Muteem and Dell's
collaboration keyboards were all broken by it.

CoughButton doesn't use that API. It drives Teams' own on-screen meeting
controls through the macOS **Accessibility API** — the same mechanism a screen
reader uses. Nothing is injected into Teams, no network traffic is involved,
and nothing is hidden.

## What it does

| Action | Default shortcut |
|---|---|
| Mute / unmute | `⌃⌥⌘M` |
| Camera on / off | `⌃⌥⌘V` |
| Raise / lower hand | `⌃⌥⌘H` |
| Push to talk (hold) | `⌃⌥⌘Space` |

All four are rebindable in Settings.

The menu-bar icon shows live state at a glance:

- **red** — you are transmitting (mic live, or camera on)
- **grey** — muted / camera off
- **orange** — the state could not be confirmed

That last one matters. **CoughButton never shows a state it hasn't verified.**
Every action presses the control and then re-reads it; if the change can't be
confirmed, you get an honest "unknown" rather than a confident lie. The failure
this app exists to prevent is believing you're muted when you're live.

Push-to-talk follows the same principle: releasing the key restores the mic to
whatever it was before you held it, and if that state was unreadable it ends
**muted**.

## Requirements

- macOS 13 or later
- Microsoft Teams (the new client, `com.microsoft.teams2`)
- **Accessibility permission** — System Settings ▸ Privacy & Security ▸
  Accessibility. The app cannot see or change anything without it.

## Install

Download the DMG from [Releases](https://github.com/vmlrodrigues/CoughButton/releases),
drag CoughButton to Applications, and launch it. It is signed with a Developer
ID and notarised by Apple. It updates itself from GitHub Releases, verifying the
signing team and Gatekeeper before installing anything.

On first launch it will ask for Accessibility permission and open Settings.

## Build from source

Requires the Swift toolchain (Xcode Command Line Tools is enough to build; the
unit tests need full Xcode for XCTest).

```sh
make local     # build CoughButton.app
make run       # launch it
make test      # run the unit tests
```

## How it works

Teams renders its UI in WebView2, which exposes a full web accessibility tree.
The meeting controls carry stable DOM identifiers — `microphone-button`,
`video-button`, `raisehands-button` — so CoughButton addresses them by id rather
than by their English labels.

Three measured findings shape the design:

1. **`AXPress` works on a background window and does not steal focus.** No
   synthesised keystrokes, no activating Teams, no ~200 ms flicker.
2. **A meeting is a separate window of the Teams process.** Its presence is the
   "in a meeting" signal, so no heuristics are needed.
3. **Reading a cached element reference costs ~0.017 ms**, against 70–200 ms for
   a tree walk. So CoughButton discovers the controls once, caches them, and
   polls at 10 Hz for effectively nothing.

State is read from the control's label, which names the action it offers and so
inverts: `"Unmute mic"` means you are currently muted.

The full investigation, including what was tested and what remains uncertain,
is in [FINDINGS.md](FINDINGS.md). The probe tools used to establish it are in
[`probe/`](probe/) and still work.

### Known limits

- **State reading depends on Teams' English labels.** The DOM ids are
  locale-independent, but the label verbs are not. On a non-English Teams the
  buttons still work; the indicator shows "unknown".
- **The DOM ids are Microsoft's to rename.** If a Teams update changes them,
  CoughButton reports that it can't find the controls rather than failing
  silently.
- Teams only. Zoom, Meet and Slack expose comparable trees, and the adapter is
  behind a protocol, so they're additions rather than rewrites.

## Privacy

CoughButton reads the accessibility tree of Microsoft Teams, and nothing else.
It has no microphone or camera entitlement — it never touches audio or video
itself, only Teams' own buttons. Its sole network use is checking GitHub
Releases for updates. No telemetry, no analytics, no accounts.

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with or endorsed by Microsoft. "Microsoft Teams" is a trademark
of Microsoft Corporation, used here only to describe compatibility.
