import XCTest
import CoreGraphics
@testable import CoughButtonKit

final class ShortcutTests: XCTestCase {

    private let cmd = CGEventFlags.maskCommand.rawValue
    private let shift = CGEventFlags.maskShift.rawValue
    private let opt = CGEventFlags.maskAlternate.rawValue
    private let ctrl = CGEventFlags.maskControl.rawValue

    // MARK: Normalisation

    /// macOS packs caps lock, the numeric-pad bit and a left/right-hand
    /// distinction into the same flags word. A chord recorded on the left
    /// Command key must still fire on the right one.
    func testNormalisationStripsNonModifierBits() {
        let noisy = cmd | CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskNumericPad.rawValue
        let shortcut = Shortcut(keyCode: 46, modifiers: noisy)
        XCTAssertEqual(shortcut.modifiers, cmd)
    }

    func testMatchIgnoresCapsLockState() {
        let shortcut = Shortcut(keyCode: 46, modifiers: cmd | shift)
        let flags = CGEventFlags(rawValue: cmd | shift | CGEventFlags.maskAlphaShift.rawValue)
        XCTAssertTrue(shortcut.matches(keyCode: 46, flags: flags))
    }

    func testMatchRequiresExactModifierSet() {
        let shortcut = Shortcut(keyCode: 46, modifiers: cmd | shift)
        XCTAssertFalse(shortcut.matches(keyCode: 46, flags: CGEventFlags(rawValue: cmd)))
        XCTAssertFalse(shortcut.matches(keyCode: 46, flags: CGEventFlags(rawValue: cmd | shift | opt)))
    }

    func testMatchRequiresSameKey() {
        let shortcut = Shortcut(keyCode: 46, modifiers: cmd)
        XCTAssertFalse(shortcut.matches(keyCode: 9, flags: CGEventFlags(rawValue: cmd)))
    }

    // MARK: Modifier predicates

    func testModifierPredicates() {
        let shortcut = Shortcut(keyCode: 0, modifiers: cmd | opt)
        XCTAssertTrue(shortcut.hasCommand)
        XCTAssertTrue(shortcut.hasOption)
        XCTAssertFalse(shortcut.hasShift)
        XCTAssertFalse(shortcut.hasControl)
    }

    /// A bare key would swallow ordinary typing system-wide; the recorder uses
    /// this to refuse one.
    func testBareKeyHasNoModifiers() {
        XCTAssertFalse(Shortcut(keyCode: 46, modifiers: 0).hasAnyModifier)
        XCTAssertTrue(Shortcut(keyCode: 46, modifiers: ctrl).hasAnyModifier)
    }

    // MARK: Display

    /// Apple's canonical modifier order is ⌃⌥⇧⌘ regardless of press order.
    func testDisplayStringUsesCanonicalModifierOrder() {
        let shortcut = Shortcut(keyCode: 46, modifiers: cmd | shift | opt | ctrl)
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘M")
    }

    func testDisplayStringForDefaults() {
        XCTAssertEqual(HotkeyAction.toggleMic.defaultShortcut.displayString, "⌃⌥⌘M")
        XCTAssertEqual(HotkeyAction.toggleCamera.defaultShortcut.displayString, "⌃⌥⌘V")
        XCTAssertEqual(HotkeyAction.raiseHand.defaultShortcut.displayString, "⌃⌥⌘H")
        XCTAssertEqual(HotkeyAction.pushToTalk.defaultShortcut.displayString, "⌃⌥⌘Space")
    }

    func testKeyNamesCoverSpecialKeys() {
        XCTAssertEqual(Shortcut.keyName(for: 49), "Space")
        XCTAssertEqual(Shortcut.keyName(for: 53), "⎋")
        XCTAssertEqual(Shortcut.keyName(for: 122), "F1")
    }

    /// Never render an empty chord, even for a key we have no name for.
    func testUnknownKeyCodeStillRenders() {
        XCTAssertFalse(Shortcut.keyName(for: 250).isEmpty)
    }

    // MARK: Codable

    func testCodableRoundTrip() throws {
        let original = Shortcut(keyCode: 46, modifiers: cmd | ctrl)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: Defaults

    func testDefaultShortcutsDoNotCollide() {
        let defaults = HotkeyAction.allCases.map(\.defaultShortcut)
        XCTAssertEqual(Set(defaults).count, defaults.count, "default bindings must be distinct")
    }

    func testOnlyPushToTalkIsMomentary() {
        XCTAssertTrue(HotkeyAction.pushToTalk.isMomentary)
        for action in HotkeyAction.allCases where action != .pushToTalk {
            XCTAssertFalse(action.isMomentary)
        }
    }
}
