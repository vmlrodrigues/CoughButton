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
    ///
    /// 3.0 s, not the original 0.6 s: exiting Teams full-screen is a macOS
    /// Space-transition animation that alone runs ~0.5–1 s (Apple does not
    /// expose a way to shorten it), on top of which Teams tears down the
    /// presenter window and rebuilds the normal one — FINDINGS.md's own
    /// fullscreen-transition measurement recorded controls absent from every
    /// window "for several seconds". 0.6 s left no margin, so the camera
    /// glyph (only drawn while `inMeeting`) visibly dropped out for that gap —
    /// invisible on full-screen *entry* only because the menu bar itself is
    /// hidden by full screen there. This tolerance only delays how promptly
    /// "no meeting" is shown after a real hang-up; it has no bearing on
    /// action safety, which `Actuator` bounds separately and much tighter.
    static let missesBeforeIdle = 30
    /// Discovery is retried on consecutive ticks during this short wake-up
    /// window. Each refresh remains non-blocking so actions cannot queue behind
    /// repeated half-second waits.
    static let rediscoveryBurst = 30
    /// Re-discovery cadence while not in a meeting, once the wake-up burst is
    /// exhausted: 90 × 0.1 s = 9 s. Kept well beyond `rediscoveryBurst` so the
    /// two windows stay distinct — true idle just polls occasionally rather
    /// than settling for good.
    static let rediscoverEvery = 90
    /// Beyond this many misses, a later recovery is a new meeting starting,
    /// not the tail of a flicker — don't log it as one.
    static let flickerReportWindow = missesBeforeIdle * 10
}

/// Confined to `MeetingController.queue`; never touched from anywhere else.
/// Internal rather than private so its poll/re-discovery logic is testable —
/// that logic decides when the menu bar says "no meeting", which is worth
/// getting right.
final class MeetingWorker: @unchecked Sendable {

    private let client: MeetingClient
    private let revertNotifier: RevertNotifying
    private var misses = 0
    /// Miss count at the moment the menu bar actually collapsed to "no
    /// meeting" (0 while that hasn't happened this outage). Lets recovery log
    /// how long the glyph was visibly wrong, not just that a miss occurred —
    /// most misses are absorbed silently and are not worth recording.
    private var wentIdleAtMisses = 0
    /// Mic state captured when push-to-talk began, so release restores what was
    /// there rather than blindly muting.
    private var pushToTalkRestore: ToggleState?
    /// True once key-down delivered an unmute that could still land after the
    /// physical key has been released.
    private var pushToTalkUnmuteDelivered = false
    /// Belief formed the moment a toggle is verified as succeeded through a
    /// minimized window: which state we believe the control now holds, and
    /// when. Compared against every later poll read (`readSnapshot`) to catch
    /// the control reverting on its own with no further CoughButton action in
    /// between — reproduced twice on 2026-08-20: a mic toggle logged
    /// ACTUATED-VIA-MINIMIZED-WINDOW, and later, with zero intervening
    /// successful presses recorded, the same control read back the opposite
    /// state. The first occurrence took roughly two minutes; the second, an
    /// unmute reverting back to muted, took roughly ten. Neither would have
    /// been caught by the 30-second window this constant originally shipped
    /// with — see CLAUDE.md gotcha 9.
    private var minimizedActuationBelief: [MeetingControl: (state: ToggleState, at: Date)] = [:]
    /// How long to keep watching a belief before assuming it settled and
    /// dropping it silently. Widened from an initial 30s to 15 minutes after
    /// both real reproductions (~2 min and ~10 min) blew straight through the
    /// original window — whatever mechanism produces this is not fast, and a
    /// diagnostic log line is cheap even if a belief outlives its usefulness.
    private static let revertWatchWindow: TimeInterval = 15 * 60

    /// The control a hotkey action reads/writes. `nil` has no meaning here —
    /// every case maps to exactly one control; it exists only to pair with
    /// the `HotkeyAction` cases file-locally without a forced switch in every
    /// caller.
    private static func control(for action: HotkeyAction) -> MeetingControl {
        switch action {
        case .toggleMic, .pushToTalk: return .mic
        case .toggleCamera: return .camera
        case .raiseHand: return .hand
        }
    }

    init(client: MeetingClient, revertNotifier: RevertNotifying = SystemRevertNotifier()) {
        self.client = client
        self.revertNotifier = revertNotifier
    }

    func tick() -> MeetingSnapshot? {
        guard AX.isTrusted else { return MeetingSnapshot(accessibilityGranted: false) }

        if client.isInMeeting {
            recordRecoveryIfNeeded()
            misses = 0
            return readSnapshot()
        }

        misses += 1
        // A stale reference or dormant WebView needs a short burst of retries;
        // after that fall back to the slow idle cadence.
        if misses <= Tuning.rediscoveryBurst || misses % Tuning.rediscoverEvery == 0 {
            client.refresh()
            if client.isInMeeting {
                recordRecoveryIfNeeded()
                misses = 0
                return readSnapshot()
            }
        }
        guard misses >= Tuning.missesBeforeIdle else { return nil }
        // The menu bar is about to visibly collapse to the single "no
        // meeting" glyph. Record only the first tick of an outage — logging
        // every subsequent miss would just restate the same event.
        if wentIdleAtMisses == 0 {
            wentIdleAtMisses = misses
        } else if misses - wentIdleAtMisses > Tuning.flickerReportWindow {
            // This has settled into a genuine "no meeting" for a while now;
            // a later recovery is a new meeting, not this outage resolving.
            wentIdleAtMisses = 0
        }
        return MeetingSnapshot(accessibilityGranted: true)
    }

    /// Only fires when a prior miss run was long enough to reach the menu bar
    /// (`wentIdleAtMisses > 0`) — a re-render absorbed within the burst is not
    /// a user-visible event and DiagLog stays quiet for it, per its contract.
    private func recordRecoveryIfNeeded() {
        guard wentIdleAtMisses > 0 else { return }
        let outageMs = Int(Double(misses) * Tuning.tickInterval * 1000)
        DiagLog.write("MEETING-FLICKER recovered after misses=\(misses) (~\(outageMs)ms) " + client.diagnostics)
        wentIdleAtMisses = 0
    }

    func readSnapshot() -> MeetingSnapshot {
        guard client.isInMeeting else {
            return MeetingSnapshot(accessibilityGranted: AX.isTrusted)
        }
        let mic = client.state(of: .mic)
        let camera = client.state(of: .camera)
        let hand = client.state(of: .hand)
        checkForSilentRevert(.mic, current: mic)
        checkForSilentRevert(.camera, current: camera)
        checkForSilentRevert(.hand, current: hand)
        return MeetingSnapshot(
            inMeeting: true,
            mic: mic,
            camera: camera,
            hand: hand,
            accessibilityGranted: true
        )
    }

    /// Compares a freshly read state against a still-active minimized-window
    /// belief for the same control. `.unknown` proves nothing either way —
    /// the tree going briefly unreadable is routine — so it neither confirms
    /// nor clears the watch.
    private func checkForSilentRevert(_ control: MeetingControl, current: ToggleState) {
        guard let belief = minimizedActuationBelief[control] else { return }
        let elapsed = Date().timeIntervalSince(belief.at)
        guard elapsed <= Self.revertWatchWindow else {
            minimizedActuationBelief[control] = nil
            return
        }
        guard current != .unknown, current != belief.state else { return }
        DiagLog.write("REVERTED-AFTER-MINIMIZED-ACTUATION \(control.rawValue) "
            + "actuatedTo=\(belief.state.rawValue) now=\(current.rawValue) "
            + "afterMs=\(Int(elapsed * 1000)) " + client.diagnostics)
        // The log line is the permanent record; this is an additional,
        // best-effort nudge so the user has a chance to notice before they
        // otherwise would — the live glyph is already correct by the very
        // next poll tick regardless, so this is purely retrospective.
        revertNotifier.notifyRevert(control: control, actuatedTo: belief.state, now: current)
        minimizedActuationBelief[control] = nil
    }

    /// Returns nil when the phase carries no action (key-up on a toggle).
    func apply(
        _ action: HotkeyAction,
        phase: HotkeyPhase,
        deadline: Date? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> ActuationResult? {
        guard action == .pushToTalk || phase == .began else { return nil }
        let originatedMinimized = client.isActingWindowMinimized
        let wokeWindow = originatedMinimized && client.prepareActingWindowForAction()
        defer {
            if wokeWindow {
                client.restoreActingWindowAfterAction()
            }
        }
        let result = perform(
            action,
            phase: phase,
            deadline: deadline,
            shouldCancel: shouldCancel
        )
        // Restore before collecting diagnostics so the line describes the
        // user's actual Dock-minimized topology, not our transient wake state.
        if wokeWindow {
            client.restoreActingWindowAfterAction()
        }
        // Only failures are recorded. A quiet log means a quiet app; anything in
        // it is a real "the hotkey didn't register" event with the window
        // context attached, which beats trying to recall it days later.
        if let result, !result.succeeded, !shouldCancel() {
            DiagLog.write("UNVERIFIED \(action.rawValue)/\(phase == .began ? "down" : "up") "
                + "presses=\(result.presses) observed=\(result.finalState.rawValue) "
                + client.diagnostics)
        }
        // A reported (not yet reproduced when this hook was first added, then
        // reproduced) symptom: a toggle can be verified as succeeded by
        // reading a minimized meeting window's own controls, while the real
        // backend state never changed — which the menu bar could then show
        // confidently and wrongly. Scoped to the momentary toggles a user
        // notices immediately, not push-to-talk, which would otherwise log on
        // every hold. See CLAUDE.md gotcha 9.
        if let result, result.succeeded, !shouldCancel() {
            let control = MeetingWorker.control(for: action)
            // Any successful action on this control is the user (or Actuator)
            // moving its state on purpose — stop watching whatever belief
            // predates it, so a later poll can't mistake a legitimate change
            // for a silent revert.
            minimizedActuationBelief[control] = nil
            if action != .pushToTalk, phase == .began, originatedMinimized {
                DiagLog.write("ACTUATED-FROM-MINIMIZED-WINDOW \(action.rawValue) "
                    + "presses=\(result.presses) observed=\(result.finalState.rawValue) "
                    + "woke=\(wokeWindow) "
                    + client.diagnostics)
                minimizedActuationBelief[control] = (result.finalState, Date())
            }
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
