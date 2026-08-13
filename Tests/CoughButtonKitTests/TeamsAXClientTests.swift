import XCTest
@testable import CoughButtonKit

final class TeamsAXClientTests: XCTestCase {

    func testNormalMeetingWindowIsRecognisedByHangupControl() {
        XCTAssertTrue(TeamsAXClient.isMeetingWindow(domIdentifiers: [
            "hangup-button"
        ]))
    }

    func testFullScreenPresenterWindowIsRecognisedWithoutHangupControl() {
        XCTAssertTrue(TeamsAXClient.isMeetingWindow(domIdentifiers: [
            "microphone-button",
            "video-button",
            "share-button"
        ]))
    }

    func testDuplicateMainWindowMicIsNotTreatedAsMeeting() {
        XCTAssertFalse(TeamsAXClient.isMeetingWindow(domIdentifiers: [
            "microphone-button"
        ]))
    }

    func testPartialPresenterControlsAreNotTreatedAsMeeting() {
        XCTAssertFalse(TeamsAXClient.isMeetingWindow(domIdentifiers: [
            "microphone-button",
            "video-button"
        ]))
    }
}
