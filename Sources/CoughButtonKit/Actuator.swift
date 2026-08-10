import Foundation

// ---------------------------------------------------------------------------
// Actuator — press, then confirm it actually took.
//
// The brief's hard requirement is that this app never ships a blind toggle: the
// dangerous failure is believing you are muted while you are live. So every
// action re-reads the control afterwards and reports what it observed, and a
// press that didn't land is retried once against a freshly-discovered element
// before we give up and say so.
//
// `wait` is injected so tests exercise the retry logic without real time.
// ---------------------------------------------------------------------------

public struct ActuationResult: Equatable, Sendable {
    public let succeeded: Bool
    public let finalState: ToggleState
    public let presses: Int

    public init(succeeded: Bool, finalState: ToggleState, presses: Int) {
        self.succeeded = succeeded
        self.finalState = finalState
        self.presses = presses
    }
}

public enum Actuator {

    /// Time between re-reads while waiting for a press to register. A
    /// cached-reference read costs ~0.017 ms, so polling this hard is free.
    public static let pollInterval: TimeInterval = 0.025

    /// How long to keep trying to *deliver* a press when the control isn't
    /// there. Measured against Teams: taking the meeting fullscreen moves it to
    /// its own Space and the meeting controls disappear from every window in
    /// the tree for **several seconds**. Failing instantly during that window
    /// is what made the hotkey look like it "didn't register".
    public static let deliveryWindow: TimeInterval = 0.5

    /// How long to watch for a delivered press to actually take effect.
    public static let watchWindow: TimeInterval = 0.5

    /// Deliberately small. A press that Teams applies late must not be pressed
    /// a second time, or the two cancel out and the mic ends up back where it
    /// started — so patience is spent on *watching*, not on extra presses.
    public static let maxPresses = 2

    /// Drive `control` to `desired`, verifying the change.
    ///
    /// Already-correct state is a no-op success with zero presses — this is what
    /// makes push-to-talk release safe to fire repeatedly.
    @discardableResult
    public static func ensure(
        _ control: MeetingControl,
        is desired: ToggleState,
        on client: MeetingClient,
        maxPresses: Int = Actuator.maxPresses,
        deliveryWindow: TimeInterval = Actuator.deliveryWindow,
        watchWindow: TimeInterval = Actuator.watchWindow,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActuationResult {
        var presses = 0

        if client.state(of: control) == desired {
            return ActuationResult(succeeded: true, finalState: desired, presses: 0)
        }

        for _ in 0..<max(1, maxPresses) {
            // 1. Deliver. If the control isn't in the tree we keep
            //    re-discovering for a while rather than giving up — a window
            //    transition removes it entirely for seconds at a time.
            var delivered = false
            var spent: TimeInterval = 0
            while spent < deliveryWindow {
                if client.press(control) { delivered = true; break }
                client.refresh()
                wait(pollInterval)
                spent += pollInterval
            }
            guard delivered else { continue }
            presses += 1

            // 2. Watch for it to take.
            var watched: TimeInterval = 0
            while watched < watchWindow {
                wait(pollInterval)
                watched += pollInterval
                if client.state(of: control) == desired {
                    return ActuationResult(succeeded: true, finalState: desired, presses: presses)
                }
            }

            // Delivered but didn't land — the likeliest cause is a reference
            // from a window Teams has since replaced, so re-discover before
            // spending the next press.
            client.refresh()
        }

        return ActuationResult(succeeded: false, finalState: client.state(of: control), presses: presses)
    }

    /// Flip `control` to the other state.
    ///
    /// When the current state is readable we know the target and can verify it.
    /// When it is not, we still honour the user's keypress — refusing to act on
    /// a deliberate hotkey would be its own kind of failure — but we report
    /// whatever we can observe afterwards rather than assuming it worked, so the
    /// menu bar shows "unknown" instead of a confident lie.
    @discardableResult
    public static func toggle(
        _ control: MeetingControl,
        on client: MeetingClient,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActuationResult {
        switch client.state(of: control) {
        case .on:
            return ensure(control, is: .off, on: client, wait: wait)
        case .off:
            return ensure(control, is: .on, on: client, wait: wait)
        case .unknown:
            client.refresh()
            switch client.state(of: control) {
            case .on:
                return ensure(control, is: .off, on: client, wait: wait)
            case .off:
                return ensure(control, is: .on, on: client, wait: wait)
            case .unknown:
                let delivered = client.press(control)
                wait(pollInterval * 4)
                let observed = client.state(of: control)
                return ActuationResult(
                    succeeded: delivered && observed != .unknown,
                    finalState: observed,
                    presses: delivered ? 1 : 0
                )
            }
        }
    }
}
