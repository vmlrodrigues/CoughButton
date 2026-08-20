import Foundation

// ---------------------------------------------------------------------------
// MeetingClient — the seam between "what we want done in the meeting" and
// "which app is actually on screen".
//
// Teams is the only implementation today, but every control is addressed
// through this protocol so a Zoom/Meet adapter is an added file rather than a
// rewrite (and so the controller can be tested against a fake).
// ---------------------------------------------------------------------------

public enum MeetingControl: String, CaseIterable, Sendable {
    case mic
    case camera
    case hand
}

/// `.on` means transmitting/raised: mic live, camera sending, hand up.
/// `.unknown` is a first-class outcome — we show it rather than guess, because
/// a confidently-wrong mute indicator is the one failure this app must not have.
public enum ToggleState: String, Equatable, Sendable {
    case on
    case off
    case unknown
}

public protocol MeetingClient: AnyObject {
    /// True when cached controls are still live.
    ///
    /// Must be *cheap* — a cached-reference check, never a tree walk. The poll
    /// loop calls this many times a second; discovery is `refresh()`'s job and
    /// the controller schedules that on its own, much slower, cadence.
    var isInMeeting: Bool { get }
    func state(of control: MeetingControl) -> ToggleState
    /// Fires the control once. `false` means the press could not be delivered
    /// at all (stale element, no meeting) — not that the state failed to change.
    func press(_ control: MeetingControl) -> Bool
    /// Re-discover the meeting window and re-cache element references.
    func refresh()

    /// A short, non-identifying description of the current window situation,
    /// used only when logging an action that could not be verified.
    ///
    /// Must never include window titles — Teams puts the meeting name, the
    /// organisation and the signed-in address in them, and this string is meant
    /// to be safe to paste into a public issue.
    var diagnostics: String { get }

    /// Whether the window currently backing actuation is minimized. Cheap by
    /// contract — same constraint as `isInMeeting`. Exists so a diagnostic line
    /// can be attached to an action originating from a minimized window.
    /// Defaults to `false` so clients that have no notion of "minimized" don't
    /// need to implement it.
    var isActingWindowMinimized: Bool { get }

    /// Temporarily makes a minimized acting window renderable without activating
    /// the meeting app. Returns whether the window was minimized and was restored
    /// by `restoreActingWindowAfterAction()`.
    ///
    /// Teams' compact WebView remains AX-readable while minimized, but real
    /// presses through it have twice read back as successful and later reverted.
    /// Waking the window removes that renderer-suspension variable while keeping
    /// the user's foreground app and Space unchanged.
    func prepareActingWindowForAction() -> Bool
    func restoreActingWindowAfterAction()
}

public extension MeetingClient {
    var diagnostics: String { "" }
    var isActingWindowMinimized: Bool { false }
    func prepareActingWindowForAction() -> Bool { false }
    func restoreActingWindowAfterAction() {}
}

// ---------------------------------------------------------------------------
// ControlLabels — deriving state from an accessibility label.
//
// Teams labels a control with the action it *offers*, not the state it is in,
// so the reading inverts: "Unmute mic" means you are currently muted. Verified
// against Teams 26198.202.4929.7171 on 7 Aug 2026.
// ---------------------------------------------------------------------------

public enum ControlLabels {

    /// Order is load-bearing. "unmute" contains "mute" as a substring, so the
    /// negated form must be tested first or every muted mic reads as live —
    /// exactly inverted, and exactly the dangerous direction.
    public static func micState(fromLabel label: String?) -> ToggleState {
        guard let l = label?.lowercased() else { return .unknown }
        if l.contains("unmute") { return .off }
        if l.contains("mute") { return .on }
        return .unknown
    }

    /// Same inversion. "Turn camera off" is offered while the camera is on.
    /// Checked before the "on" form for the same substring reason as mic.
    public static func cameraState(fromLabel label: String?) -> ToggleState {
        guard let l = label?.lowercased() else { return .unknown }
        if l.contains("camera off") { return .on }
        if l.contains("camera on") { return .off }
        return .unknown
    }

    /// "Raise your hand" is offered while the hand is down.
    public static func handState(fromLabel label: String?) -> ToggleState {
        guard let l = label?.lowercased() else { return .unknown }
        if l.contains("lower") { return .on }
        if l.contains("raise") { return .off }
        return .unknown
    }

    public static func state(of control: MeetingControl, fromLabel label: String?) -> ToggleState {
        switch control {
        case .mic: return micState(fromLabel: label)
        case .camera: return cameraState(fromLabel: label)
        case .hand: return handState(fromLabel: label)
        }
    }
}
