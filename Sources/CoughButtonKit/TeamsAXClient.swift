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
// Three behaviours here are the result of measured findings, not guesses:
//
//  1. A meeting is a *separate window* of the same process. Its presence is the
//     "in a meeting" signal — no heuristics required.
//  2. `microphone-button` is NOT unique: the main window carries one too, and
//     mid-toggle the two briefly disagree. Every lookup is therefore scoped to
//     the meeting window.
//  3. References go stale on re-render, and modal dialogs (Teams' "Invite
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
    }

    private var meetingWindow: AXUIElement?
    private var buttons: [MeetingControl: AXUIElement] = [:]

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

    /// A meeting window is the one whose subtree contains the hang-up button.
    private func locateMeetingWindow(pid: pid_t) -> AXUIElement? {
        for window in AX.windows(ofPID: pid) {
            let hit = AX.firstDescendant(of: window, maxDepth: 45) { Self.domID($0) == DOM.hangup }
            if hit != nil { return window }
        }
        return nil
    }

    public func refresh() {
        meetingWindow = nil
        buttons.removeAll()

        guard AX.isTrusted, let pid = teamsPID(), let window = locateMeetingWindow(pid: pid) else { return }
        meetingWindow = window

        let wanted: [MeetingControl: String] = [
            .mic: DOM.mic, .camera: DOM.camera, .hand: DOM.hand
        ]
        for (control, id) in wanted {
            if let element = AX.firstDescendant(of: window, maxDepth: 45, where: { Self.domID($0) == id }) {
                buttons[control] = element
            }
        }
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

    /// Returns a live element for `control`, re-discovering when the cached
    /// reference is stale *or* its window has been replaced.
    private func element(for control: MeetingControl) -> AXUIElement? {
        if let cached = buttons[control], cachedWindowIsCurrent(), !AX.isStale(cached) {
            return cached
        }
        refresh()
        return buttons[control]
    }

    // MARK: MeetingClient

    /// Cheap by contract: one cached-reference read, no walking. Returning
    /// `false` here means "re-discover soon", not "the meeting has ended" —
    /// the controller decides that after several consecutive misses.
    public var isInMeeting: Bool {
        guard let cached = buttons[.mic], cachedWindowIsCurrent() else { return false }
        return !AX.isStale(cached)
    }

    public func state(of control: MeetingControl) -> ToggleState {
        guard let element = element(for: control) else { return .unknown }
        return ControlLabels.state(of: control, fromLabel: AX.label(element))
    }

    public func press(_ control: MeetingControl) -> Bool {
        guard let element = element(for: control) else { return false }
        return AX.press(element)
    }

    /// Shape of the window situation, with no titles — see the protocol note.
    /// This is the context that makes a failed action diagnosable: which window
    /// modes were in play when the controls went missing.
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
            let hasControls = AX.firstDescendant(of: window, maxDepth: 45) {
                Self.domID($0) == DOM.hangup
            } != nil
            parts.append(hasControls ? "controls" : "no-controls")
            return parts.joined(separator: "/")
        }
        return "windows=[\(shapes.joined(separator: ", "))] cached=\(buttons.count)"
    }
}
