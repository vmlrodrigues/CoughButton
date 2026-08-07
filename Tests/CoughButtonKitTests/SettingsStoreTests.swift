import XCTest
import CoreGraphics
@testable import CoughButtonKit

final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "coughbutton.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnsetActionReturnsItsDefault() {
        XCTAssertEqual(store.shortcut(for: .toggleMic), HotkeyAction.toggleMic.defaultShortcut)
    }

    func testAllActionsHaveABindingOutOfTheBox() {
        XCTAssertEqual(store.allBindings.count, HotkeyAction.allCases.count)
        XCTAssertTrue(store.allBindings.allSatisfy { $0.shortcut != nil })
    }

    func testSetAndReadBack() {
        let custom = Shortcut(keyCode: 15, modifiers: CGEventFlags.maskCommand.rawValue)
        store.setShortcut(custom, for: .toggleMic)
        XCTAssertEqual(store.shortcut(for: .toggleMic), custom)
    }

    func testPersistsAcrossStoreInstances() {
        let custom = Shortcut(keyCode: 15, modifiers: CGEventFlags.maskCommand.rawValue)
        store.setShortcut(custom, for: .raiseHand)

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.shortcut(for: .raiseHand), custom)
    }

    /// Clearing must stick. If it fell back to the default the binding would
    /// reappear on next launch, which reads as the app ignoring the user.
    func testClearedBindingStaysCleared() {
        store.setShortcut(nil, for: .pushToTalk)
        XCTAssertNil(store.shortcut(for: .pushToTalk))

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertNil(reopened.shortcut(for: .pushToTalk))
    }

    func testRebindingAfterClearingWorks() {
        store.setShortcut(nil, for: .pushToTalk)
        let custom = Shortcut(keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue)
        store.setShortcut(custom, for: .pushToTalk)
        XCTAssertEqual(store.shortcut(for: .pushToTalk), custom)
    }

    func testResetRestoresDefaultsIncludingClearedBindings() {
        store.setShortcut(nil, for: .toggleMic)
        store.setShortcut(Shortcut(keyCode: 15, modifiers: CGEventFlags.maskCommand.rawValue), for: .raiseHand)

        store.resetToDefaults()

        XCTAssertEqual(store.shortcut(for: .toggleMic), HotkeyAction.toggleMic.defaultShortcut)
        XCTAssertEqual(store.shortcut(for: .raiseHand), HotkeyAction.raiseHand.defaultShortcut)
    }

    // MARK: Conflicts

    func testConflictDetectedAgainstAnotherAction() {
        let shared = HotkeyAction.toggleCamera.defaultShortcut
        XCTAssertEqual(store.conflict(for: shared, excluding: .toggleMic), .toggleCamera)
    }

    /// Re-recording the same chord onto the row that already owns it is not a
    /// clash, or the UI would reject a no-op edit.
    func testNoConflictWithSelf() {
        let own = HotkeyAction.toggleMic.defaultShortcut
        XCTAssertNil(store.conflict(for: own, excluding: .toggleMic))
    }

    func testNoConflictForAnUnusedChord() {
        let unused = Shortcut(keyCode: 120, modifiers: CGEventFlags.maskControl.rawValue)
        XCTAssertNil(store.conflict(for: unused, excluding: .toggleMic))
    }

    func testClearedBindingCannotConflict() {
        store.setShortcut(nil, for: .toggleCamera)
        let freed = HotkeyAction.toggleCamera.defaultShortcut
        XCTAssertNil(store.conflict(for: freed, excluding: .toggleMic))
    }
}
