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

    /// Time between re-reads while waiting for a press to register. Teams'
    /// tree updates well inside this; a cached-reference read costs ~0.017 ms,
    /// so polling this hard is free.
    public static let pollInterval: TimeInterval = 0.025
    public static let pollsPerAttempt = 8      // ≈200 ms per attempt
    public static let maxAttempts = 2

    /// Drive `control` to `desired`, verifying the change.
    ///
    /// Already-correct state is a no-op success with zero presses — this is what
    /// makes push-to-talk release safe to fire repeatedly.
    @discardableResult
    public static func ensure(
        _ control: MeetingControl,
        is desired: ToggleState,
        on client: MeetingClient,
        maxAttempts: Int = Actuator.maxAttempts,
        pollsPerAttempt: Int = Actuator.pollsPerAttempt,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ActuationResult {
        var presses = 0

        if client.state(of: control) == desired {
            return ActuationResult(succeeded: true, finalState: desired, presses: 0)
        }

        for attempt in 1...max(1, maxAttempts) {
            if client.press(control) {
                presses += 1
                for _ in 0..<max(1, pollsPerAttempt) {
                    wait(pollInterval)
                    let observed = client.state(of: control)
                    if observed == desired {
                        return ActuationResult(succeeded: true, finalState: desired, presses: presses)
                    }
                }
            }
            // Either the press could not be delivered, or it did not take.
            // A stale reference is much the likelier cause, so re-discover
            // before the last attempt rather than hammering a dead element.
            if attempt < maxAttempts { client.refresh() }
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
