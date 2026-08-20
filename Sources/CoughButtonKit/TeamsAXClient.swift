import Foundation
import ApplicationServices
import AppKit

// ---------------------------------------------------------------------------
// TeamsAXClient — drives Microsoft Teams through the Accessibility API.
//
// Teams renders its UI in WebView2, which exposes the full web accessibility
// tree. The meeting controls carry stable DOM ids, so we address them by id
// rather than by their English labels, and read state from the label only.
//
// Five behaviours here are the result of measured findings, not guesses:
//
//  1. WebView2 sometimes needs an Accessibility activation hint before it
//     materialises its web tree.
//  2. A meeting is a *separate window* of the same process. Its presence is the
//     "in a meeting" signal — no heuristics required.
//  3. While sharing full-screen, the presenter window omits `hangup-button` but
//     keeps the mic, camera, and share controls.
//  4. `microphone-button` is NOT unique: the main window carries one too, and
//     mid-toggle the two briefly disagree. Every lookup is therefore scoped to
//     the meeting window.
//  5. References go stale on re-render, and modal dialogs (Teams' "Invite
//     people" popup is aria-modal) blank the rest of the tree entirely. Both
//     are transient, so discovery failure is never treated as "meeting ended"
//     without a retry.
//
// Not thread-safe by itself: MeetingController confines it to one serial queue.
// ---------------------------------------------------------------------------

public final class TeamsAXClient: MeetingClient, @unchecked Sendable {

    /// New Teams first, classic as a fallback.
    public static let bundleIdentifiers = ["com.microsoft.teams2", "com.microsoft.teams"]

    /// Locale-independent handles, verified against Teams 26198.202.4929.7171.
    private enum DOM {
        static let hangup = "hangup-button"
        static let mic = "microphone-button"
        static let camera = "video-button"
        static let hand = "raisehands-button"
        static let share = "share-button"
    }

    private static let knownDOMIdentifiers: Set<String> = [
        DOM.hangup, DOM.mic, DOM.camera, DOM.hand, DOM.share
    ]
    private var meetingWindow: AXUIElement?
    private var buttons: [MeetingControl: AXUIElement] = [:]
    /// The DOM id each cached element had *at discovery time*. WebView2/Chromium
    /// can recycle an accessibility node to represent a different DOM element
    /// after a re-render, without invalidating the reference — the same class
    /// of bug documented above for window swaps, but for individual controls.
    /// A recycled node still passes `isStale`/`cachedWindowIsCurrent`, so it is
    /// re-verified against this recorded id before every press or read; a
    /// mismatch is treated exactly like staleness (cause a refresh) rather than
    /// trusting the dictionary key forever.
    private var expectedDOMIDs: [MeetingControl: String] = [:]

    public init() {}

    // MARK: Discovery

    private func teamsPID() -> pid_t? {
        for id in Self.bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app.processIdentifier
            }
        }
        return nil
    }

    private static func domID(_ element: AXUIElement) -> String? { AX.domIdentifier(element) }

    /// Finds the known controls in one bounded walk, avoiding a separate full
    /// traversal for every button.
    private static func knownElements(in window: AXUIElement) -> [String: AXUIElement] {
        var found: [String: AXUIElement] = [:]
        var remaining = 20_000

        func walk(_ element: AXUIElement, depth: Int) {
            guard remaining > 0, depth <= 45 else { return }
            remaining -= 1
            if let id = domID(element), knownDOMIdentifiers.contains(id) {
                found[id] = element
            }
            for child in AX.children(element) {
                walk(child, depth: depth + 1)
            }
        }

        walk(window, depth: 0)
        return found
    }

    /// Normal meeting windows contain hang-up. Teams' full-screen presenter
    /// window does not, so its locale-independent signature is the combination
    /// of mic + camera + share. Requiring all three avoids the duplicate mic
    /// button exposed by the main Teams window.
    static func isMeetingWindow(domIdentifiers: Set<String>) -> Bool {
        if domIdentifiers.contains(DOM.hangup) { return true }
        return domIdentifiers.contains(DOM.mic)
            && domIdentifiers.contains(DOM.camera)
            && domIdentifiers.contains(DOM.share)
    }

    private func locateMeetingWindow(
        pid: pid_t
    ) -> (window: AXUIElement, elements: [String: AXUIElement])? {
        for window in AX.windows(ofPID: pid) {
            let elements = Self.knownElements(in: window)
            if Self.isMeetingWindow(domIdentifiers: Set(elements.keys)) {
                return (window, elements)
            }
        }
        return nil
    }

    public func refresh() {
        meetingWindow = nil
        buttons.removeAll()
        expectedDOMIDs.removeAll()

        guard AX.isTrusted, let pid = teamsPID() else { return }

        // WebView2 can leave the native Teams windows visible while their web
        // accessibility children are only empty groups. Without this activation
        // hint, discovery can miss every control indefinitely even though a
        // meeting is in progress.
        AX.prepareWebAccessibility(ofPID: pid)

        // Activation is asynchronous. MeetingWorker performs a bounded burst of
        // refreshes on consecutive poll ticks, and Actuator does the same inside
        // its wall-clock delivery budget. Do not block here: a blocking refresh
        // can compound into a dangerously late push-to-talk release.
        guard let located = locateMeetingWindow(pid: pid) else { return }
        meetingWindow = located.window

        let wanted: [MeetingControl: String] = [
            .mic: DOM.mic, .camera: DOM.camera, .hand: DOM.hand
        ]
        for (control, id) in wanted {
            if let element = located.elements[id] {
                buttons[control] = element
                expectedDOMIDs[control] = id
            }
        }
    }

    /// The cached element for `control`, but only if it is still the same
    /// window, not stale, *and* still reports the DOM id we discovered it
    /// under. That third check is what catches a recycled node: without it, a
    /// cached "mic" reference silently repurposed to the camera button would
    /// still pass every other guard, and a press would land on the wrong
    /// control with no error to show for it.
    private func verifiedElement(for control: MeetingControl) -> AXUIElement? {
        guard let cached = buttons[control],
              let expected = expectedDOMIDs[control],
              cachedWindowIsCurrent(),
              !AX.isStale(cached),
              Self.domID(cached) == expected
        else { return nil }
        return cached
    }

    /// Is the window we discovered against still one of Teams' current windows?
    ///
    /// This is the check that `AX.isStale` cannot do. Teams swaps between the
    /// full meeting window and a **compact-view `AXSystemDialog`** as you move
    /// around, and each swap rebuilds the toolbar. Elements from the replaced
    /// window are frequently *detached rather than invalidated*: they keep
    /// answering reads with their last-known label instead of returning
    /// `kAXErrorInvalidUIElement`.
    ///
    /// That is worse than a dead reference. `Actuator.toggle` reads the current
    /// state to decide which way to go, so a stale label makes it choose the
    /// wrong direction and press the mic the opposite way — which shows up as
    /// "the hotkey sometimes doesn't register", and can leave you live when you
    /// asked to be muted.
    ///
    /// Comparing against the live window list costs one AX call, not a tree
    /// walk, so it is affordable on the 10 Hz poll.
    private func cachedWindowIsCurrent() -> Bool {
        guard let window = meetingWindow, let pid = teamsPID() else { return false }
        return AX.windows(ofPID: pid).contains { CFEqual($0, window) }
    }

    // MARK: MeetingClient

    /// Cheap by contract: a couple of cached-reference reads, no walking.
    /// Returning `false` here means "re-discover soon", not "the meeting has
    /// ended" — the controller decides that after several consecutive misses.
    public var isInMeeting: Bool {
        verifiedElement(for: .mic) != nil
    }

    public func state(of control: MeetingControl) -> ToggleState {
        guard let cached = verifiedElement(for: control) else { return .unknown }
        return ControlLabels.state(of: control, fromLabel: AX.label(cached))
    }

    public func press(_ control: MeetingControl) -> Bool {
        guard let cached = verifiedElement(for: control) else { return false }
        return AX.press(cached)
    }

    /// Shape of the window situation, with no titles — see the protocol note.
    /// This is the context that makes a failed action diagnosable: which window
    /// modes were in play when the controls went missing. The window currently
    /// backing actuation (if any) is marked `*acting*` so a log line can be
    /// correlated with exactly which window a press/read went through.
    public var diagnostics: String {
        guard let pid = teamsPID() else { return "teams=absent" }
        let windows = AX.windows(ofPID: pid)
        let shapes = windows.map { window -> String in
            var parts = [AX.string(window, kAXSubroleAttribute) ?? "?"]
            if (AX.attribute(window, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true {
                parts.append("min")
            }
            if (AX.attribute(window, "AXFullScreen") as? NSNumber)?.boolValue == true {
                parts.append("full")
            }
            let ids = Set(Self.knownElements(in: window).keys)
            let hasControls = Self.isMeetingWindow(domIdentifiers: ids)
            parts.append(hasControls ? "controls" : "no-controls")
            if let meetingWindow, CFEqual(window, meetingWindow) {
                parts.append("acting")
            }
            return parts.joined(separator: "/")
        }
        return "windows=[\(shapes.joined(separator: ", "))] cached=\(buttons.count)"
    }

    /// Cheap signal for whether the window currently backing actuation is
    /// minimized. Not used to change press/verify behaviour — neither pressing
    /// nor reading a minimized window's controls is known to be unsafe, only
    /// reported as *possibly* silently ineffective. Exists purely so a
    /// diagnostic line can capture hard evidence the next time this is seen,
    /// rather than relying on an after-the-fact account of which window was in
    /// play. See CLAUDE.md gotcha 9.
    public var isActingWindowMinimized: Bool {
        guard let meetingWindow else { return false }
        return (AX.attribute(meetingWindow, kAXMinimizedAttribute) as? NSNumber)?.boolValue == true
    }
}
