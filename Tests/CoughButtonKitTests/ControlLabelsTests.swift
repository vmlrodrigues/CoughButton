import XCTest
@testable import CoughButtonKit

/// The highest-stakes logic in the app. Teams labels a control with the action
/// it offers, so every reading is inverted — and "unmute" contains "mute" as a
/// substring, so a naive check reports every muted mic as live. That is the
/// exact failure the product must never have, hence the coverage here.
final class ControlLabelsTests: XCTestCase {

    // MARK: Mic

    func testUnmuteLabelMeansCurrentlyMuted() {
        XCTAssertEqual(ControlLabels.micState(fromLabel: "Unmute mic"), .off)
    }

    func testMuteLabelMeansCurrentlyLive() {
        XCTAssertEqual(ControlLabels.micState(fromLabel: "Mute mic"), .on)
    }

    /// The substring trap: if "mute" were tested first, "Unmute mic" would read
    /// as live and the menu bar would show the opposite of the truth.
    func testUnmuteIsNotMatchedAsMute() {
        XCTAssertNotEqual(ControlLabels.micState(fromLabel: "Unmute mic"),
                          ControlLabels.micState(fromLabel: "Mute mic"))
    }

    /// The pre-join screen appends the keyboard shortcut to the same label.
    func testMicLabelWithShortcutSuffix() {
        XCTAssertEqual(ControlLabels.micState(fromLabel: "Unmute mic (⇧ ⌘ M)"), .off)
        XCTAssertEqual(ControlLabels.micState(fromLabel: "Mute mic (⇧ ⌘ M)"), .on)
    }

    func testMicLabelIsCaseInsensitive() {
        XCTAssertEqual(ControlLabels.micState(fromLabel: "UNMUTE MIC"), .off)
        XCTAssertEqual(ControlLabels.micState(fromLabel: "mute mic"), .on)
    }

    // MARK: Camera

    func testCameraOnLabelMeansCurrentlyOff() {
        XCTAssertEqual(ControlLabels.cameraState(fromLabel: "Turn camera on"), .off)
    }

    func testCameraOffLabelMeansCurrentlyOn() {
        XCTAssertEqual(ControlLabels.cameraState(fromLabel: "Turn camera off"), .on)
    }

    func testCameraLabelWithShortcutSuffix() {
        XCTAssertEqual(ControlLabels.cameraState(fromLabel: "Turn camera on (⇧ ⌘ O)"), .off)
    }

    // MARK: Hand

    func testRaiseLabelMeansHandDown() {
        XCTAssertEqual(ControlLabels.handState(fromLabel: "Raise your hand"), .off)
    }

    func testLowerLabelMeansHandUp() {
        XCTAssertEqual(ControlLabels.handState(fromLabel: "Lower your hand"), .on)
    }

    // MARK: Unknown

    /// Anything we don't recognise must be `.unknown`, never a guess. A relabel
    /// in a future Teams build should degrade to "we can't tell", which the UI
    /// shows honestly, rather than silently inverting.
    func testUnrecognisedLabelIsUnknown() {
        XCTAssertEqual(ControlLabels.micState(fromLabel: "Mikrofon stummschalten"), .unknown)
        XCTAssertEqual(ControlLabels.cameraState(fromLabel: "Kamera einschalten"), .unknown)
        XCTAssertEqual(ControlLabels.handState(fromLabel: "Hand heben"), .unknown)
    }

    func testNilLabelIsUnknown() {
        for control in MeetingControl.allCases {
            XCTAssertEqual(ControlLabels.state(of: control, fromLabel: nil), .unknown)
        }
    }

    func testEmptyLabelIsUnknown() {
        XCTAssertEqual(ControlLabels.micState(fromLabel: ""), .unknown)
    }

    // MARK: Dispatch

    func testStateDispatchesToTheRightControl() {
        XCTAssertEqual(ControlLabels.state(of: .mic, fromLabel: "Mute mic"), .on)
        XCTAssertEqual(ControlLabels.state(of: .camera, fromLabel: "Turn camera off"), .on)
        XCTAssertEqual(ControlLabels.state(of: .hand, fromLabel: "Lower your hand"), .on)
    }
}
