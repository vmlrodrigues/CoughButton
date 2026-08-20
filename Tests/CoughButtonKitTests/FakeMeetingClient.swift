import Foundation
@testable import CoughButtonKit

/// A controllable stand-in for Teams, so the actuation logic can be tested
/// without a running meeting. Models the parts that actually bite in practice:
/// presses that are delivered but don't take (stale element), presses that
/// can't be delivered at all, and controls whose state can't be read.
final class FakeMeetingClient: MeetingClient {

    var inMeeting = true
    var states: [MeetingControl: ToggleState] = [.mic: .off, .camera: .off, .hand: .off]

    private(set) var pressCount = 0
    private(set) var refreshCount = 0

    /// Presses that are accepted but have no effect — what a stale reference
    /// looks like from the outside.
    var pressesToSwallow = 0
    /// `press` returns false: could not be delivered at all.
    var pressUndeliverable = false
    /// Every state read comes back `.unknown`.
    var reportsUnknown = false
    /// Simulates an action originating from the minimized compact Teams window.
    var actingWindowIsMinimized = false
    private(set) var prepareForActionCount = 0
    private(set) var restoreAfterActionCount = 0
    /// Whether preparing a minimized acting window succeeds.
    var canWakeActingWindow = true
    private var hasPreparedWindowToRestore = false
    /// Applied by `refresh()`, so a test can make re-discovery "fix" things.
    var onRefresh: ((FakeMeetingClient) -> Void)?

    var isInMeeting: Bool { inMeeting }
    var isActingWindowMinimized: Bool { actingWindowIsMinimized }

    func prepareActingWindowForAction() -> Bool {
        prepareForActionCount += 1
        guard actingWindowIsMinimized, canWakeActingWindow else { return false }
        actingWindowIsMinimized = false
        hasPreparedWindowToRestore = true
        return true
    }

    func restoreActingWindowAfterAction() {
        guard hasPreparedWindowToRestore else { return }
        hasPreparedWindowToRestore = false
        restoreAfterActionCount += 1
        actingWindowIsMinimized = true
    }

    func state(of control: MeetingControl) -> ToggleState {
        if reportsUnknown { return .unknown }
        return states[control] ?? .unknown
    }

    func press(_ control: MeetingControl) -> Bool {
        if pressUndeliverable { return false }
        pressCount += 1
        if pressesToSwallow > 0 {
            pressesToSwallow -= 1
            return true
        }
        states[control] = (states[control] == .on) ? .off : .on
        return true
    }

    func refresh() {
        refreshCount += 1
        onRefresh?(self)
    }
}

/// No-op wait, so retry logic runs at full speed in tests.
let instantly: (TimeInterval) -> Void = { _ in }

/// Records revert notifications without touching UNUserNotificationCenter,
/// so tests can assert the user-facing nudge fires exactly when the log line
/// does — and never otherwise.
final class FakeRevertNotifier: RevertNotifying {
    private(set) var notifications: [(control: MeetingControl, actuatedTo: ToggleState, now: ToggleState)] = []

    func notifyRevert(control: MeetingControl, actuatedTo: ToggleState, now: ToggleState) {
        notifications.append((control, actuatedTo, now))
    }
}
