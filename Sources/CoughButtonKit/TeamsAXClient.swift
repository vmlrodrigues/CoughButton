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

    /// Returns a live element for `control`, re-discovering once if the cached
    /// reference has gone stale.
    private func element(for control: MeetingControl) -> AXUIElement? {
        if let cached = buttons[control], !AX.isStale(cached) { return cached }
        refresh()
        return buttons[control]
    }

    // MARK: MeetingClient

    /// Cheap by contract: one cached-reference read, no walking. Returning
    /// `false` here means "re-discover soon", not "the meeting has ended" —
    /// the controller decides that after several consecutive misses.
    public var isInMeeting: Bool {
        guard let cached = buttons[.mic] else { return false }
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
}
