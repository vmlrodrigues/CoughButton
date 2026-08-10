import XCTest
@testable import CoughButtonKit

/// Covers the "never a blind toggle" guarantee: an action either verifiably
/// took effect, or reports that it didn't.
final class ActuatorTests: XCTestCase {

    func testEnsureIsNoOpWhenAlreadyInDesiredState() {
        let client = FakeMeetingClient()
        client.states[.mic] = .on

        let result = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.presses, 0, "must not press a control that is already correct")
        XCTAssertEqual(client.pressCount, 0)
    }

    func testEnsureFlipsAndVerifies() {
        let client = FakeMeetingClient()
        client.states[.mic] = .off

        let result = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.presses, 1)
        XCTAssertEqual(result.finalState, .on)
    }

    /// A press that is accepted but doesn't take — the stale-reference case.
    /// The actuator should re-discover and try again rather than believe it.
    func testEnsureRetriesAfterSwallowedPress() {
        let client = FakeMeetingClient()
        client.states[.camera] = .off
        client.pressesToSwallow = 1

        let result = Actuator.ensure(.camera, is: .on, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.presses, 2, "should press again after the first was swallowed")
        XCTAssertEqual(client.refreshCount, 1, "should re-discover between attempts")
    }

    func testEnsureReportsFailureWhenPressCannotBeDelivered() {
        let client = FakeMeetingClient()
        client.states[.mic] = .off
        client.pressUndeliverable = true

        let result = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.presses, 0)
    }

    /// The transition case, measured against Teams: taking a meeting fullscreen
    /// moves it to its own Space and the controls vanish from every window for
    /// seconds. Failing instantly is what made the hotkey look like it "didn't
    /// register" — the actuator must keep re-discovering until they return.
    func testEnsureWaitsOutAControlThatIsTemporarilyMissing() {
        let client = FakeMeetingClient()
        client.states[.mic] = .off
        client.pressUndeliverable = true
        var refreshes = 0
        client.onRefresh = { c in
            refreshes += 1
            if refreshes >= 3 { c.pressUndeliverable = false }
        }

        let result = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded, "a control that comes back mid-transition must still be actuated")
        XCTAssertEqual(result.finalState, .on)
        XCTAssertEqual(result.presses, 1)
    }

    /// Patience is spent on *watching*, never on extra presses: a press Teams
    /// applies late must not be pressed again, or the two cancel out and the
    /// mic ends up back where it started.
    func testEnsureNeverExceedsThePressBudget() {
        let client = FakeMeetingClient()
        client.states[.mic] = .off
        client.pressesToSwallow = 99

        let result = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)

        XCTAssertLessThanOrEqual(client.pressCount, Actuator.maxPresses)
        XCTAssertFalse(result.succeeded)
    }

    func testEnsureGivesUpAfterMaxAttempts() {
        let client = FakeMeetingClient()
        client.states[.mic] = .off
        client.pressesToSwallow = 99      // never takes

        let result = Actuator.ensure(.mic, is: .on, on: client, wait: instantly)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.presses, Actuator.maxPresses)
    }

    // MARK: Toggle

    func testToggleFlipsFromOn() {
        let client = FakeMeetingClient()
        client.states[.mic] = .on

        let result = Actuator.toggle(.mic, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.finalState, .off)
    }

    func testToggleFlipsFromOff() {
        let client = FakeMeetingClient()
        client.states[.hand] = .off

        let result = Actuator.toggle(.hand, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.finalState, .on)
    }

    /// Unreadable state must trigger a re-discovery attempt before anything else.
    func testToggleRefreshesWhenStateIsUnknown() {
        let client = FakeMeetingClient()
        client.reportsUnknown = true

        _ = Actuator.toggle(.mic, on: client, wait: instantly)

        XCTAssertGreaterThan(client.refreshCount, 0)
    }

    /// If re-discovery recovers the state, the toggle proceeds as a normal
    /// verified flip.
    func testToggleRecoversWhenRefreshRestoresReadableState() {
        let client = FakeMeetingClient()
        client.reportsUnknown = true
        client.states[.mic] = .off
        client.onRefresh = { $0.reportsUnknown = false }

        let result = Actuator.toggle(.mic, on: client, wait: instantly)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.finalState, .on)
    }

    /// Still unreadable after a refresh: we honour the keypress but must NOT
    /// claim success, so the menu bar shows "unknown" rather than a guess.
    func testToggleWithPermanentlyUnknownStateActsButReportsUnverified() {
        let client = FakeMeetingClient()
        client.reportsUnknown = true

        let result = Actuator.toggle(.mic, on: client, wait: instantly)

        XCTAssertFalse(result.succeeded, "must not report success it cannot verify")
        XCTAssertEqual(result.finalState, .unknown)
        XCTAssertEqual(client.pressCount, 1, "the user's keypress is still honoured")
    }
}
