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
    /// Applied by `refresh()`, so a test can make re-discovery "fix" things.
    var onRefresh: ((FakeMeetingClient) -> Void)?

    var isInMeeting: Bool { inMeeting }

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
