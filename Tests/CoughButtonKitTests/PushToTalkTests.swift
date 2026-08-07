import XCTest
@testable import CoughButtonKit

/// Push-to-talk release policy. Of the two ways to be wrong, leaving a mic open
/// is the one that matters, so anything short of "known live beforehand" ends
/// muted.
final class PushToTalkTests: XCTestCase {

    func testMicThatWasLiveBeforehandStaysLive() {
        XCTAssertEqual(MeetingController.pushToTalkRestoreTarget(priorState: .on), .on)
    }

    func testMicThatWasMutedGoesBackToMuted() {
        XCTAssertEqual(MeetingController.pushToTalkRestoreTarget(priorState: .off), .off)
    }

    /// The important one: if we couldn't read the prior state, we mute.
    func testUnknownPriorStateEndsMuted() {
        XCTAssertEqual(MeetingController.pushToTalkRestoreTarget(priorState: .unknown), .off)
    }

    /// End-to-end through the actuator: hold unmutes, release re-mutes.
    func testHoldAndReleaseCycleReturnsToMuted() {
        let client = FakeMeetingClient()
        client.states[.mic] = .off

        let prior = client.state(of: .mic)
        let began = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)
        XCTAssertTrue(began.succeeded)
        XCTAssertEqual(client.state(of: .mic), .on)

        let target = MeetingController.pushToTalkRestoreTarget(priorState: prior)
        let ended = Actuator.ensure(.mic, is: target, on: client, wait: instantly)
        XCTAssertTrue(ended.succeeded)
        XCTAssertEqual(client.state(of: .mic), .off, "release must return the mic to muted")
    }

    /// Holding push-to-talk while already unmuted must not mute you on release.
    func testHoldWhileAlreadyLiveLeavesMicLive() {
        let client = FakeMeetingClient()
        client.states[.mic] = .on

        let prior = client.state(of: .mic)
        _ = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)
        XCTAssertEqual(client.pressCount, 0, "already live — nothing to do")

        let target = MeetingController.pushToTalkRestoreTarget(priorState: prior)
        _ = Actuator.ensure(.mic, is: target, on: client, wait: instantly)
        XCTAssertEqual(client.state(of: .mic), .on)
    }
}
