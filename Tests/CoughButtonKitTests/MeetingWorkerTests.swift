import XCTest
@testable import CoughButtonKit

/// The poll loop's re-discovery behaviour: how long it tolerates losing sight
/// of the meeting before telling the user there isn't one.
///
/// This matters because Teams invalidates element references on every re-render
/// and blanks the whole tree while a modal dialog is open. Reacting to the first
/// miss would make the menu bar flap between "in a meeting" and "no meeting"
/// several times a minute; never reacting would leave it lying after you hang up.
///
/// These tests run with Accessibility granted (the AX gate is a real system call
/// and is not mocked); on a machine without it the guard short-circuits, so they
/// are skipped rather than reported as failures.
final class MeetingWorkerTests: XCTestCase {

    private func requireAccessibility() throws {
        try XCTSkipUnless(AX.isTrusted, "needs Accessibility permission for the poll-loop path")
    }

    func testReportsStateWhileInMeeting() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.states = [.mic: .off, .camera: .on, .hand: .off]
        let worker = MeetingWorker(client: client)

        let snapshot = worker.tick()

        XCTAssertEqual(snapshot?.inMeeting, true)
        XCTAssertEqual(snapshot?.mic, .off)
        XCTAssertEqual(snapshot?.camera, .on)
    }

    /// A single miss is almost always a stale reference, so it must trigger an
    /// immediate re-discovery rather than waiting for the slow cadence.
    func testFirstMissTriggersImmediateRediscovery() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        _ = worker.tick()

        XCTAssertEqual(client.refreshCount, 1)
    }

    /// If re-discovery finds the meeting again, nothing should reach the UI as
    /// an interruption — this is the re-render case, and it must be invisible.
    func testRecoveredMeetingNeverReportsIdle() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        client.onRefresh = { $0.inMeeting = true }
        let worker = MeetingWorker(client: client)

        let snapshot = worker.tick()

        XCTAssertEqual(snapshot?.inMeeting, true, "a recovered reference must not surface as 'no meeting'")
    }

    /// Below the threshold the worker returns nil — "nothing to say yet" —
    /// rather than prematurely publishing idle.
    func testWithholdsIdleUntilThreshold() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        for tick in 1..<Tuning.missesBeforeIdle {
            XCTAssertNil(worker.tick(), "should stay quiet on miss \(tick)")
        }
    }

    func testReportsIdleOnceThresholdIsReached() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        var last: MeetingSnapshot?
        for _ in 0..<Tuning.missesBeforeIdle { last = worker.tick() }

        XCTAssertEqual(last?.inMeeting, false)
        XCTAssertEqual(last?.accessibilityGranted, true)
    }

    /// Leaving and rejoining has to work without recreating the worker.
    func testMissCounterResetsWhenMeetingReturns() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)
        for _ in 0..<Tuning.missesBeforeIdle { _ = worker.tick() }

        client.inMeeting = true
        XCTAssertEqual(worker.tick()?.inMeeting, true)

        client.inMeeting = false
        for tick in 1..<Tuning.missesBeforeIdle {
            XCTAssertNil(worker.tick(), "counter should have reset; miss \(tick) must stay quiet")
        }
    }

    /// Discovery runs in a bounded burst while WebView wakes, then stops until
    /// the slow idle cadence rather than walking continuously.
    func testRediscoveryBurstIsBoundedWhileIdle() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        for _ in 0..<(Tuning.rediscoverEvery - 1) { _ = worker.tick() }

        XCTAssertEqual(client.refreshCount, Tuning.rediscoveryBurst)
    }

    func testRediscoversAgainOnTheSlowCadence() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        for _ in 0..<Tuning.rediscoverEvery { _ = worker.tick() }

        XCTAssertEqual(client.refreshCount, Tuning.rediscoveryBurst + 1)
    }

    func testMeetingCanRecoverLateInWakeupBurst() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        client.onRefresh = { client in
            if client.refreshCount == Tuning.rediscoveryBurst {
                client.inMeeting = true
            }
        }
        let worker = MeetingWorker(client: client)

        var snapshot: MeetingSnapshot?
        for _ in 0..<Tuning.rediscoveryBurst {
            snapshot = worker.tick()
        }

        XCTAssertEqual(snapshot?.inMeeting, true)
        XCTAssertEqual(client.refreshCount, Tuning.rediscoveryBurst)
    }

    /// Regression for the camera glyph vanishing when Teams exits
    /// full-screen: macOS's own Space-transition animation runs ~0.5–1 s
    /// before Teams even rebuilds its window, which is longer than the old
    /// 0.6 s budget but must stay well inside the current one.
    func testAbsorbsAFullScreenExitLengthGapWithoutGoingIdle() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        // 15 ticks == 1.5 s of the meeting window being unfindable while the
        // old window is torn down and the new one materialises.
        let gapTicks = 15
        client.onRefresh = { client in
            if client.refreshCount == gapTicks {
                client.inMeeting = true
            }
        }
        let worker = MeetingWorker(client: client)

        var everWentIdle = false
        var last: MeetingSnapshot?
        for _ in 0..<gapTicks {
            last = worker.tick()
            if last?.inMeeting == false { everWentIdle = true }
        }

        XCTAssertFalse(everWentIdle, "a gap shorter than missesBeforeIdle must never surface as 'no meeting'")
        XCTAssertEqual(last?.inMeeting, true)
    }

    // MARK: Actions

    func testKeyUpOnAToggleDoesNothing() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        let worker = MeetingWorker(client: client)

        XCTAssertNil(worker.apply(.toggleMic, phase: .ended))
        XCTAssertEqual(client.pressCount, 0, "a toggle must fire once per press, not again on release")
    }

    func testPushToTalkUnmutesOnPressAndRemutesOnRelease() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.states[.mic] = .off
        let worker = MeetingWorker(client: client)

        _ = worker.apply(.pushToTalk, phase: .began)
        XCTAssertEqual(client.state(of: .mic), .on)

        _ = worker.apply(.pushToTalk, phase: .ended)
        XCTAssertEqual(client.state(of: .mic), .off)
    }

    /// Holding push-to-talk while already live must not mute you on release.
    func testPushToTalkLeavesAnAlreadyLiveMicLive() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.states[.mic] = .on
        let worker = MeetingWorker(client: client)

        _ = worker.apply(.pushToTalk, phase: .began)
        _ = worker.apply(.pushToTalk, phase: .ended)

        XCTAssertEqual(client.state(of: .mic), .on)
    }

    func testReadSnapshotOutsideAMeetingIsNotInMeeting() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        XCTAssertEqual(worker.readSnapshot().inMeeting, false)
    }

    /// Reported (not reproduced) symptom: a toggle verified as succeeded
    /// through a minimized meeting window, while the real state allegedly
    /// never changed. No behaviour change follows from this alone — only a
    /// diagnostic line, so a recurrence carries hard evidence.
    ///
    /// The log file is shared across the whole test run (one `COUGHBUTTON_LOG_DIR`
    /// per `swift test` invocation), so assertions only inspect bytes appended
    /// *after* this test's own action, never the file's full history — otherwise
    /// test order could make an unrelated write look like this test's own.
    func testLogsWhenATogglesSucceedsThroughAMinimizedWindow() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = true
        client.states[.mic] = .off
        let worker = MeetingWorker(client: client)

        let before = logSizeNow()
        _ = worker.apply(.toggleMic, phase: .began)

        XCTAssertTrue(
            newLogContent(since: before).contains("ACTUATED-VIA-MINIMIZED-WINDOW toggleMic"),
            "a succeeded toggle through a minimized window must be logged for evidence"
        )
    }

    /// The common case — not minimized — must stay quiet, matching the
    /// existing "only genuinely informative events" logging philosophy.
    func testStaysQuietWhenATogglesSucceedsThroughANonMinimizedWindow() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = false
        client.states[.camera] = .off
        let worker = MeetingWorker(client: client)

        let before = logSizeNow()
        _ = worker.apply(.toggleCamera, phase: .began)

        XCTAssertFalse(newLogContent(since: before).contains("ACTUATED-VIA-MINIMIZED-WINDOW"))
    }

    /// Push-to-talk fires on every hold; scoped out of the minimized-window
    /// diagnostic so normal use doesn't flood the log.
    func testPushToTalkThroughAMinimizedWindowDoesNotLog() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = true
        client.states[.mic] = .off
        let worker = MeetingWorker(client: client)

        let before = logSizeNow()
        _ = worker.apply(.pushToTalk, phase: .began)

        XCTAssertFalse(newLogContent(since: before).contains("ACTUATED-VIA-MINIMIZED-WINDOW"))
    }

    /// The scenario that actually happened on 2026-08-20: a mic toggle logged
    /// ACTUATED-VIA-MINIMIZED-WINDOW/on, and a later poll read the same
    /// control back as muted with no intervening CoughButton action. This is
    /// the diagnostic that would prove it wasn't a one-off — simulated here
    /// by changing the fake's underlying state directly (standing in for the
    /// real backend reverting it on its own).
    func testDetectsAStateThatRevertsAfterAMinimizedWindowActuation() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = true
        client.states[.mic] = .off
        let notifier = FakeRevertNotifier()
        let worker = MeetingWorker(client: client, revertNotifier: notifier)

        _ = worker.apply(.toggleMic, phase: .began)
        XCTAssertEqual(client.state(of: .mic), .on, "the fake's own toggle should have flipped it")

        client.states[.mic] = .off // nothing in CoughButton touched this

        let before = logSizeNow()
        _ = worker.readSnapshot()

        XCTAssertTrue(
            newLogContent(since: before).contains("REVERTED-AFTER-MINIMIZED-ACTUATION mic actuatedTo=on now=off"),
            "a control reverting with no intervening CoughButton action must be logged"
        )
        XCTAssertEqual(notifier.notifications.count, 1, "the user-facing nudge must fire alongside the log line")
        XCTAssertEqual(notifier.notifications.first?.control, .mic)
        XCTAssertEqual(notifier.notifications.first?.actuatedTo, .on)
        XCTAssertEqual(notifier.notifications.first?.now, .off)
    }

    /// The common case: the control keeps reading back what was believed —
    /// must stay quiet indefinitely, not just on the first read.
    func testStaysQuietWhenStateMatchesTheMinimizedWindowBelief() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = true
        client.states[.mic] = .off
        let notifier = FakeRevertNotifier()
        let worker = MeetingWorker(client: client, revertNotifier: notifier)

        _ = worker.apply(.toggleMic, phase: .began)

        let before = logSizeNow()
        _ = worker.readSnapshot()
        _ = worker.readSnapshot()

        XCTAssertFalse(newLogContent(since: before).contains("REVERTED-AFTER-MINIMIZED-ACTUATION"))
        XCTAssertTrue(notifier.notifications.isEmpty, "no revert means no nudge")
    }

    /// A later, intentional toggle of the same control — even through a
    /// normal window — must clear the earlier belief rather than have its own
    /// legitimate state change mistaken for an unprompted revert.
    func testDoesNotMisreportALaterIntentionalToggleAsARevert() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = true
        client.states[.mic] = .off
        let notifier = FakeRevertNotifier()
        let worker = MeetingWorker(client: client, revertNotifier: notifier)

        _ = worker.apply(.toggleMic, phase: .began) // off -> on, belief recorded

        client.actingWindowIsMinimized = false
        _ = worker.apply(.toggleMic, phase: .began) // on -> off, the user's own doing

        let before = logSizeNow()
        _ = worker.readSnapshot()

        XCTAssertFalse(newLogContent(since: before).contains("REVERTED-AFTER-MINIMIZED-ACTUATION"))
        XCTAssertTrue(notifier.notifications.isEmpty, "a legitimate later toggle must not trigger the nudge")
    }

    /// `.unknown` (a momentarily unreadable tree) must neither confirm nor
    /// silently clear an active belief — the watch has to survive a blip and
    /// still catch the revert once the control becomes readable again.
    func testUnknownReadingsDoNotClearTheRevertWatch() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.actingWindowIsMinimized = true
        client.states[.mic] = .off
        let notifier = FakeRevertNotifier()
        let worker = MeetingWorker(client: client, revertNotifier: notifier)

        _ = worker.apply(.toggleMic, phase: .began) // belief: mic = on

        client.reportsUnknown = true
        let duringBlip = logSizeNow()
        _ = worker.readSnapshot()
        XCTAssertFalse(newLogContent(since: duringBlip).contains("REVERTED-AFTER-MINIMIZED-ACTUATION"))
        XCTAssertTrue(notifier.notifications.isEmpty, "an unreadable tree must not trigger the nudge")

        client.reportsUnknown = false
        client.states[.mic] = .off
        let afterBlip = logSizeNow()
        _ = worker.readSnapshot()
        XCTAssertTrue(newLogContent(since: afterBlip).contains("REVERTED-AFTER-MINIMIZED-ACTUATION"))
        XCTAssertEqual(notifier.notifications.count, 1, "the nudge fires once the control becomes readable again")
    }

    // MARK: Log helpers

    /// Current byte length of the (redirected) diagnostic log, or 0 if it
    /// doesn't exist yet. `DiagLog` writes asynchronously, so callers must
    /// settle before reading — see `newLogContent(since:)`.
    private func logSizeNow() -> Int {
        settleLogQueue()
        return (try? FileManager.default.attributesOfItem(atPath: DiagLog.fileURL.path))?[.size] as? Int ?? 0
    }

    /// The portion of the log written after byte offset `before` — never the
    /// whole file, since it accumulates entries across the entire test run.
    private func newLogContent(since before: Int) -> String {
        settleLogQueue()
        guard let data = try? Data(contentsOf: DiagLog.fileURL), data.count > before else { return "" }
        return String(data: data.suffix(from: before), encoding: .utf8) ?? ""
    }

    /// `DiagLog.write` dispatches asynchronously onto its own serial queue;
    /// give it a moment to land before reading the file back.
    private func settleLogQueue() {
        let expectation = XCTestExpectation(description: "log write settles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
    }
}
