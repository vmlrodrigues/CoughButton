import Foundation
import Combine

// ---------------------------------------------------------------------------
// MeetingController — owns the poll loop and publishes the state the menu bar
// renders.
//
// Split in two on purpose:
//
//   MeetingWorker      confined to one serial queue; all Accessibility work
//                      lives here. Discovery costs 70–200 ms and has no
//                      business on the main thread.
//   MeetingController  @MainActor; holds only published state.
//
// A state read off a cached reference costs ~0.017 ms, which is what makes
// polling at 10 Hz affordable in the first place.
// ---------------------------------------------------------------------------

public struct MeetingSnapshot: Equatable, Sendable {
    public var inMeeting: Bool
    public var mic: ToggleState
    public var camera: ToggleState
    public var hand: ToggleState
    public var accessibilityGranted: Bool

    public init(
        inMeeting: Bool = false,
        mic: ToggleState = .unknown,
        camera: ToggleState = .unknown,
        hand: ToggleState = .unknown,
        accessibilityGranted: Bool = true
    ) {
        self.inMeeting = inMeeting
        self.mic = mic
        self.camera = camera
        self.hand = hand
        self.accessibilityGranted = accessibilityGranted
    }

    public static let idle = MeetingSnapshot()
}

public enum HotkeyPhase: Sendable { case began, ended }

/// Poll cadence and the tolerances around losing sight of the meeting.
enum Tuning {
    static let tickInterval: TimeInterval = 0.1
    /// Consecutive misses tolerated before declaring the meeting over. Absorbs
    /// the brief reference invalidation and asynchronous WebView wake-up Teams
    /// causes, so the menu bar doesn't flap or report idle prematurely.
    static let missesBeforeIdle = 6
    /// Discovery is retried on consecutive ticks during this short wake-up
    /// window. Each refresh remains non-blocking so actions cannot queue behind
    /// repeated half-second waits.
    static let rediscoveryBurst = 6
    /// Re-discovery cadence while not in a meeting: 20 × 0.1 s = 2 s.
    static let rediscoverEvery = 20
}

/// Confined to `MeetingController.queue`; never touched from anywhere else.
/// Internal rather than private so its poll/re-discovery logic is testable —
/// that logic decides when the menu bar says "no meeting", which is worth
/// getting right.
final class MeetingWorker: @unchecked Sendable {

    private let client: MeetingClient
    private var misses = 0
    /// Mic state captured when push-to-talk began, so release restores what was
    /// there rather than blindly muting.
    private var pushToTalkRestore: ToggleState?
    /// True once key-down delivered an unmute that could still land after the
    /// physical key has been released.
    private var pushToTalkUnmuteDelivered = false

    init(client: MeetingClient) {
        self.client = client
    }

    func tick() -> MeetingSnapshot? {
        guard AX.isTrusted else { return MeetingSnapshot(accessibilityGranted: false) }

        if client.isInMeeting {
            misses = 0
            return readSnapshot()
        }

        misses += 1
        // A stale reference or dormant WebView needs a short burst of retries;
        // after that fall back to the slow idle cadence.
        if misses <= Tuning.rediscoveryBurst || misses % Tuning.rediscoverEvery == 0 {
            client.refresh()
            if client.isInMeeting {
                misses = 0
                return readSnapshot()
            }
        }
        return misses >= Tuning.missesBeforeIdle ? MeetingSnapshot(accessibilityGranted: true) : nil
    }

    func readSnapshot() -> MeetingSnapshot {
        guard client.isInMeeting else {
            return MeetingSnapshot(accessibilityGranted: AX.isTrusted)
        }
        return MeetingSnapshot(
            inMeeting: true,
            mic: client.state(of: .mic),
            camera: client.state(of: .camera),
            hand: client.state(of: .hand),
            accessibilityGranted: true
        )
    }

    /// Returns nil when the phase carries no action (key-up on a toggle).
    func apply(
        _ action: HotkeyAction,
        phase: HotkeyPhase,
        deadline: Date? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> ActuationResult? {
        let result = perform(
            action,
            phase: phase,
            deadline: deadline,
            shouldCancel: shouldCancel
        )
        // Only failures are recorded. A quiet log means a quiet app; anything in
        // it is a real "the hotkey didn't register" event with the window
        // context attached, which beats trying to recall it days later.
        if let result, !result.succeeded, !shouldCancel() {
            DiagLog.write("UNVERIFIED \(action.rawValue)/\(phase == .began ? "down" : "up") "
                + "presses=\(result.presses) observed=\(result.finalState.rawValue) "
                + client.diagnostics)
        }
        return result
    }

    private func perform(
        _ action: HotkeyAction,
        phase: HotkeyPhase,
        deadline: Date?,
        shouldCancel: @escaping () -> Bool
    ) -> ActuationResult? {
        switch action {
        case .toggleMic:
            guard phase == .began else { return nil }
            return Actuator.toggle(.mic, on: client)
        case .toggleCamera:
            guard phase == .began else { return nil }
            return Actuator.toggle(.camera, on: client)
        case .raiseHand:
            guard phase == .began else { return nil }
            return Actuator.toggle(.hand, on: client)
        case .pushToTalk:
            switch phase {
            case .began:
                pushToTalkRestore = client.state(of: .mic)
                pushToTalkUnmuteDelivered = false
                let result = Actuator.ensure(
                    .mic,
                    is: .on,
                    on: client,
                    shouldCancel: shouldCancel
                )
                pushToTalkUnmuteDelivered = result.presses > 0
                return result
            case .ended:
                let target = MeetingController.pushToTalkRestoreTarget(priorState: pushToTalkRestore ?? .unknown)
                pushToTalkRestore = nil
                let unmuteMayStillLand = pushToTalkUnmuteDelivered
                pushToTalkUnmuteDelivered = false
                if target == .off && unmuteMayStillLand {
                    let releaseDeadline = deadline
                        ?? Date().addingTimeInterval(Actuator.deliveryWindow + Actuator.watchWindow)
                    return Actuator.ensureSettled(
                        .mic,
                        is: .off,
                        on: client,
                        until: releaseDeadline
                    )
                }
                return Actuator.ensure(
                    .mic,
                    is: target,
                    on: client,
                    deadline: deadline
                )
            }
        }
    }
}

private final class ActionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

@MainActor
public final class MeetingController: ObservableObject {

    @Published public private(set) var snapshot: MeetingSnapshot = .idle

    /// Raised when an action was delivered but could not be confirmed. Shown
    /// rather than swallowed, because a state we don't know is not a state we
    /// should be rendering confidently.
    @Published public private(set) var lastActionUnverified = false

    private let worker: MeetingWorker
    private let queue = DispatchQueue(label: "com.victorrodrigues.coughbutton.ax", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pushToTalkCancellation: ActionCancellation?

    public init(client: MeetingClient = TeamsAXClient()) {
        self.worker = MeetingWorker(client: client)
    }

    // MARK: Lifecycle

    public func start() {
        guard timer == nil else { return }
        let worker = self.worker
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: Tuning.tickInterval)
        source.setEventHandler { [weak self] in
            guard let next = worker.tick() else { return }
            Task { @MainActor in self?.publish(next) }
        }
        timer = source
        source.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func publish(_ next: MeetingSnapshot) {
        if snapshot != next { snapshot = next }
    }

    // MARK: Actions

    public func perform(_ action: HotkeyAction, phase: HotkeyPhase = .began) {
        let worker = self.worker
        let cancellation: ActionCancellation?
        let deadline: Date?

        if action == .pushToTalk {
            switch phase {
            case .began:
                pushToTalkCancellation?.cancel()
                let token = ActionCancellation()
                pushToTalkCancellation = token
                cancellation = token
                deadline = nil
            case .ended:
                cancellation = pushToTalkCancellation
                cancellation?.cancel()
                pushToTalkCancellation = nil
                deadline = Date().addingTimeInterval(
                    Actuator.deliveryWindow + Actuator.watchWindow
                )
            }
        } else {
            cancellation = nil
            deadline = nil
        }

        queue.async { [weak self] in
            let result = worker.apply(
                action,
                phase: phase,
                deadline: deadline,
                shouldCancel: { cancellation?.isCancelled ?? false }
            )
            let latest = worker.readSnapshot()
            Task { @MainActor in
                guard let self else { return }
                self.publish(latest)
                if let result { self.lastActionUnverified = !result.succeeded }
            }
        }
    }

    /// Where push-to-talk should leave the mic on release.
    ///
    /// Only a mic that was *known* to be live beforehand stays live; muted or
    /// unreadable both end muted. Unknown resolving to muted is deliberate — of
    /// the two ways to be wrong, leaving a mic open is the one that matters.
    nonisolated public static func pushToTalkRestoreTarget(priorState: ToggleState) -> ToggleState {
        priorState == .on ? .on : .off
    }
}
