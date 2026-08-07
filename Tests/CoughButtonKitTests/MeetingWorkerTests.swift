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

    /// Discovery is expensive (70–200 ms), so it must not run on every tick
    /// while idle — only on the first miss and then on the slow cadence.
    func testDoesNotRediscoverOnEveryTickWhileIdle() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        for _ in 0..<(Tuning.rediscoverEvery - 1) { _ = worker.tick() }

        XCTAssertEqual(client.refreshCount, 1, "only the first miss should have re-discovered")
    }

    func testRediscoversAgainOnTheSlowCadence() throws {
        try requireAccessibility()
        let client = FakeMeetingClient()
        client.inMeeting = false
        let worker = MeetingWorker(client: client)

        for _ in 0..<Tuning.rediscoverEvery { _ = worker.tick() }

        XCTAssertEqual(client.refreshCount, 2)
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
}
