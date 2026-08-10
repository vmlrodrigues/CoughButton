# Findings — driving Microsoft Teams through the Accessibility API

Everything below was established by measurement against Teams
`26198.202.4929.7171` on macOS, 7 August 2026. The probe tools that produced it
are in [`probe/`](probe/) — run `make` in that directory to build them.

The short version: Teams' WebView2 exposes its full web accessibility tree, the
meeting controls carry stable locale-independent DOM ids, and `AXPress` drives
them from the background with **no focus steal and no keystroke synthesis at
all**. The activate-send-restore flicker this approach usually requires turns out
to be unnecessary.

---

## Background

Microsoft permanently retired the Teams local third-party API — the WebSocket on
`127.0.0.1:8124` that mute buttons and hardware relied on (notice MC1266901,
effective 30 June 2026). The Settings ▸ Privacy ▸ "Third-party app API" toggle
was removed, there is no replacement, and no admin setting restores it.

Teams' server-pushed configuration now carries
`"thirdPartyDevices":{"thirdPartyDevicesManagerEnabled":false}`, which both
closes the socket and hides the settings toggle. `127.0.0.1:8124` refuses
connections; Teams has no listening socket at all.

## 1. Accessibility permission

`AXIsProcessTrusted()` returns true for a granted process, and every subsequent
AX read and write against Teams succeeds.

One precision worth keeping: a binary launched from a terminal inherits TCC
attribution from its parent process. That does **not** demonstrate that a new
app bundle will be granted — an app needs its own entry in Privacy & Security ▸
Accessibility. Nothing about the mechanism is unusual; it is the ordinary
one-time prompt.

## 2. Teams keyboard shortcuts

Read out of Teams' own shortcut editor (Settings and more ▸ Keyboard shortcuts),
so this is the live truth for this build rather than documentation:

| Action | Shortcut |
|---|---|
| Toggle mute | `⇧⌘M` |
| Toggle video | `⇧⌘O` |
| Temporarily unmute (push-to-talk) | `⌥Space` |
| Toggle background blur | `⇧⌘P` |
| Raise or lower your hand | `⇧⌘K` |
| Start video call | `⇧⌘S` |
| Accept video call | `⇧⌘V` |

**Every row in that dialog is an "Edit shortcut for…" button — these are
user-remappable.** Anything that hardcodes them is betting on a default.
CoughButton doesn't use them at all, which sidesteps the problem entirely.

## 3. Background delivery

Tested with Teams *not* frontmost, verified by reading state back out of the AX
tree rather than by eye:

- **`AXUIElementPerformAction(element, kAXPressAction)`** — works, returns in
  0 ms, **does not steal focus**.
- **`CGEventPostToPid(teamsPid, event)`** — also works while backgrounded.

An early test did show Teams jumping to the front, which looked like the
expected problem. It was a red herring: that press hit an app-bar navigation
item, and it is Teams' own navigation handler that raises the window. Re-tested
against a non-navigating toggle, both delivery paths left focus untouched.

## 4. Reading state

In-meeting controls, with stable DOM identifiers:

| Control | DOM id | Role |
|---|---|---|
| Mic | `microphone-button` | `AXButton` |
| Camera | `video-button` | `AXButton` |
| Raise hand | `raisehands-button` | `AXButton` |
| Leave | `hangup-button` | `AXButton` |
| Share | `share-button` | `AXButton` |
| React | `reaction-menu-button` | `AXButton` |

State is encoded in the label, which names the *action available* and therefore
inverts to give current state:

- `"Unmute mic"` → currently **muted** · `"Mute mic"` → currently **live**
- `"Turn camera on"` → currently **off** · `"Turn camera off"` → currently **on**

Confirmed end-to-end: a backgrounded `AXPress` on `microphone-button` flipped
`"Unmute mic"` → `"Mute mic"`, and on `video-button` flipped
`"Turn camera on"` → `"Turn camera off"`. Focus never moved.

### Performance

- Full tree walk: **70–200 ms** — do this rarely.
- Read of a **cached** element reference: **0.017 ms** (1000-read average).

So: walk once to find the controls, cache the `AXUIElement` references, then
poll them at 10–20 Hz for essentially nothing.

### Other mechanics

- A meeting is a **separate `AXWindow` on the same pid**. Its existence is a
  clean "in a meeting" signal — no heuristics needed. But **the subrole varies**:
  the full meeting window is `AXStandardWindow`, while Teams' *compact view* is
  an `AXSystemDialog`. Never filter on subrole; locate the window by finding
  `hangup-button` inside it.
- The **pre-join screen** uses a different shape: `AXCheckBox[AXSwitch]` with a
  real `value=0/1` *and* the shortcut in the label (`"Unmute mic (⇧⌘M)"`).
- **AX notifications do fire.** Observer registration succeeds for
  `AXValueChanged`, `AXFocusedUIElementChanged`, `AXLayoutChanged`,
  `AXLiveRegionChanged` and `AXTitleChanged`, and events arrive with element and
  value attached. However a dependable `AXValueChanged` on a toggle flip was not
  observed, so notifications are best treated as an accelerator rather than the
  source of truth. Cheap polling is the primary mechanism.

### There is no boolean state attribute — settled

The obvious hope is that Teams sets `aria-pressed` on the mic button, which
Chromium would surface as a numeric `AXValue`, giving a language-independent
read. **It does not.** All 45 attributes of the in-meeting `microphone-button`
were enumerated with `axctl attrs` during a live meeting:

| Attribute | Muted | Live |
|---|---|---|
| `AXRole` | `AXButton` | `AXButton` |
| `AXSubrole` | *unsupported* | *unsupported* |
| `AXValue` | *empty* | *empty* |
| `AXSelected` | `0` | `0` |
| **`AXDescription`** | **"Unmute mic"** | **"Mute mic"** |

`AXDescription` is the *only* attribute that changes. `AXSelected` looks
promising and is not — it stays `0` across the toggle. `video-button` has the
identical shape. So the label verb genuinely is the only state signal available,
and the English dependency cannot be removed from within the AX tree.

Note the contrast with elsewhere in Teams: the app-bar tabs are
`AXCheckBox[AXToggleButton]` with a real `value`, and the **pre-join** mic is
`AXCheckBox[AXSwitch]` with `value=0/1`. Teams does use proper toggle semantics
— just not on the in-meeting controls. Testing the pre-join switch tells you
nothing about the in-meeting button; they are different implementations.

**Two useful things did fall out of that dump:**

- **`AXKeyShortcutsValue`** carries the control's *current* Teams shortcut
  (`⇧ ⌘ M`, `⇧ ⌘ O`) as a proper attribute. It is language-independent and
  reflects user remapping, so it is a good secondary way to identify which
  control is which if the DOM ids ever change.
- The route to locale independence is **outside** the AX tree: detect whether
  the microphone is actually capturing (CoreAudio / the system mic-in-use
  signal) and use that to *calibrate* the labels once. Observe which label is
  present while the hardware is live, and you have learned the mapping for any
  language, automatically, without shipping a locale table. That is the real
  follow-up.

### Four gotchas

1. **Modal dialogs blank the tree.** Teams' "Invite people to join you" popup is
   `aria-modal`, so while it is open the entire rest of the meeting UI is absent
   from the AX tree. A lookup must tolerate this and retry rather than
   concluding the meeting ended.
2. **`microphone-button` is not unique.** The main window carries one as well as
   the meeting window, and mid-toggle the two briefly disagree (`"Mute mic"` vs
   `"Unmute mic"`). Scope every lookup to the meeting window; never take the
   first match.
3. **References go stale on re-render.** Cache them, but detect
   `kAXErrorInvalidUIElement` and re-find.
4. **`kAXErrorInvalidUIElement` is not enough on its own.** Teams swaps between
   the full meeting window and the compact-view dialog as you navigate, and
   elements orphaned by that swap are often *detached rather than invalidated* —
   they keep answering reads with their last-known label instead of erroring. A
   stale label is worse than a dead reference, because it makes a toggle choose
   the wrong direction. Also check that the window you discovered against is
   still in the app's live window list (one AX call, not a walk).

## 5. Resulting architecture

Pure Accessibility. No synthesised keystrokes, no focus stealing, no CoreAudio in
the primary path.

Synthesised shortcuts (`⇧⌘M`) do work backgrounded, but they are
fire-and-forget, they depend on user-remappable bindings, and they report no
state. `AXPress` on a specific element is targeted, confirmable, and reads state
from the same tree it acts on.

**Never a blind toggle.** Every action is press → re-read → confirm the label
actually flipped. If it didn't: re-find the element, retry once, and failing
that surface an explicit "unknown" rather than a confident wrong answer. Given a
0.017 ms read, this costs nothing.

**Push-to-talk** is `keydown → AXPress(unmute)`, `keyup → AXPress(mute)`, each
verified, and requires `CGEventTap` rather than `RegisterEventHotKey` to get
key-up at all. Teams' own `⌥Space` is not used because it needs Teams focused.

### Known limits

- **Label verbs are English.** The DOM ids are locale-independent but the state
  read is not. On a non-English Teams the controls still work; the indicator
  shows "unknown". See below — this is not fixable from the AX tree alone.
- **DOM ids are Microsoft's to rename.** They are stable across a session and
  look deliberate, but an update can change them. Mitigated with an ordered
  fallback — DOM id → toolbar position → label match — surfacing a clear
  "adapter needs updating" state rather than failing silently.
- **This generalises.** Zoom, Meet and Slack huddles expose comparable trees.
  The per-app knowledge is small enough — a handful of ids plus two label verbs
  — that an adapter protocol is the right shape, which is why `MeetingClient`
  exists.
