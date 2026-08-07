import XCTest
@testable import CoughButtonKit

final class UpdaterTests: XCTestCase {

    func testHigherPatchIsNewer() {
        XCTAssertTrue(Updater.isNewer("0.1.1", than: "0.1.0"))
    }

    func testHigherMinorIsNewer() {
        XCTAssertTrue(Updater.isNewer("0.2.0", than: "0.1.9"))
    }

    func testHigherMajorIsNewer() {
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "0.9.9"))
    }

    func testEqualIsNotNewer() {
        XCTAssertFalse(Updater.isNewer("1.2.3", than: "1.2.3"))
    }

    func testLowerIsNotNewer() {
        XCTAssertFalse(Updater.isNewer("1.2.2", than: "1.2.3"))
    }

    /// Numeric, not lexicographic — "0.10.0" must beat "0.9.0".
    func testDoubleDigitComponentsCompareNumerically() {
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(Updater.isNewer("0.9.0", than: "0.10.0"))
    }

    func testDifferingComponentCountsAreHandled() {
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0"))
    }

    func testGarbageComponentsDoNotCrash() {
        XCTAssertFalse(Updater.isNewer("nonsense", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.0.0", than: "nonsense"))
    }
}

final class StatusSummaryTests: XCTestCase {

    func testPermissionMissingTakesPrecedence() {
        let snapshot = MeetingSnapshot(inMeeting: true, mic: .on, accessibilityGranted: false)
        XCTAssertEqual(StatusIcon.summary(for: snapshot), "Accessibility permission needed")
    }

    func testIdleSummary() {
        XCTAssertEqual(StatusIcon.summary(for: .idle), "No meeting detected")
    }

    func testLiveSummaryNamesBothControls() {
        let snapshot = MeetingSnapshot(inMeeting: true, mic: .on, camera: .off, hand: .off)
        XCTAssertEqual(StatusIcon.summary(for: snapshot), "Mic live · Camera off")
    }

    func testMutedSummary() {
        let snapshot = MeetingSnapshot(inMeeting: true, mic: .off, camera: .on, hand: .off)
        XCTAssertEqual(StatusIcon.summary(for: snapshot), "Mic muted · Camera on")
    }

    /// Unknown must read as unknown, never as a definite state.
    func testUnknownIsSurfacedNotGuessed() {
        let snapshot = MeetingSnapshot(inMeeting: true, mic: .unknown, camera: .off, hand: .off)
        XCTAssertTrue(StatusIcon.summary(for: snapshot).contains("unknown"))
    }
}
