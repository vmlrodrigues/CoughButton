import UserNotifications

// ---------------------------------------------------------------------------
// RevertNotifier — surfaces a REVERTED-AFTER-MINIMIZED-ACTUATION event (see
// CLAUDE.md gotcha 9) to the user, not just the diagnostic log.
//
// The live menu-bar glyph is already correct on every poll tick regardless of
// this bug — this is not about "what state are we in right now" (we know
// that, from the same read that detected the mismatch). It's retrospective:
// a press CoughButton told the user had succeeded may not actually have
// stuck. A narrow protocol keeps this out of tests entirely; UNUserNotification
// is never touched outside SystemRevertNotifier.
// ---------------------------------------------------------------------------

protocol RevertNotifying {
    func notifyRevert(control: MeetingControl, actuatedTo: ToggleState, now: ToggleState)
}

/// Best-effort local notification. Never blocks, never surfaces an error —
/// a denied or not-yet-authorised permission just means the nudge is silently
/// skipped; the diagnostic log line is written regardless by the caller.
final class SystemRevertNotifier: RevertNotifying {

    private var didRequestAuthorization = false

    func notifyRevert(control: MeetingControl, actuatedTo: ToggleState, now: ToggleState) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "CoughButton"
        content.body = "Your \(control.displayName) may not have actually \(actuatedTo.verbPhrase(for: control)) — "
            + "it read back \(actuatedTo.displayPhrase(for: control)) a little while ago but now reads "
            + "\(now.displayPhrase(for: control)). Please check \(control.displayName) directly in Teams."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "revert-\(control.rawValue)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Requested lazily, once, only when there is actually something to tell
    /// the user — an agent app asking for a permission it may never use would
    /// be a needless prompt on every launch.
    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

extension MeetingControl {
    var displayName: String {
        switch self {
        case .mic: return "mic"
        case .camera: return "camera"
        case .hand: return "raised hand"
        }
    }
}

extension ToggleState {
    /// Past-tense verb describing the transition this state represents, for
    /// the given control — e.g. mic .off → "muted", camera .on → "turned on".
    func verbPhrase(for control: MeetingControl) -> String {
        switch (control, self) {
        case (.mic, .on): return "unmuted"
        case (.mic, .off): return "muted"
        case (.camera, .on): return "turned on"
        case (.camera, .off): return "turned off"
        case (.hand, .on): return "raised"
        case (.hand, .off): return "lowered"
        case (_, .unknown): return "changed"
        }
    }

    /// Present-tense state description for the given control — e.g.
    /// mic .off → "muted", camera .on → "on".
    func displayPhrase(for control: MeetingControl) -> String {
        switch (control, self) {
        case (.mic, .on): return "unmuted"
        case (.mic, .off): return "muted"
        case (.camera, .on): return "on"
        case (.camera, .off): return "off"
        case (.hand, .on): return "raised"
        case (.hand, .off): return "lowered"
        case (_, .unknown): return "unknown"
        }
    }
}
