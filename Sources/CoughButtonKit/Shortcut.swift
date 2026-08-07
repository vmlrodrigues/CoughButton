import Foundation
import CoreGraphics

// ---------------------------------------------------------------------------
// Shortcut — a global hotkey chord: one key plus its modifier set.
//
// Deliberately free of AppKit and of any event-tap machinery so the whole type,
// including its display formatting and its matching rules, is unit-testable.
// ---------------------------------------------------------------------------

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    /// Raw `CGEventFlags`, already reduced to the four device-independent
    /// modifier bits by `Shortcut.normalise(flags:)`.
    public var modifiers: UInt64

    public init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = Shortcut.normalise(flags: modifiers)
    }

    public init(keyCode: UInt16, flags: CGEventFlags) {
        self.init(keyCode: keyCode, modifiers: flags.rawValue)
    }

    // MARK: Modifier handling

    /// The only modifier bits we care about. Everything else that macOS packs
    /// into `CGEventFlags` — caps lock, numeric pad, the left/right-hand
    /// distinction, the "fn" bit — is discarded so that a chord recorded on one
    /// side of the keyboard still matches when pressed on the other.
    public static let modifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue

    public static func normalise(flags: UInt64) -> UInt64 { flags & modifierMask }

    public var hasCommand: Bool { modifiers & CGEventFlags.maskCommand.rawValue != 0 }
    public var hasShift: Bool { modifiers & CGEventFlags.maskShift.rawValue != 0 }
    public var hasOption: Bool { modifiers & CGEventFlags.maskAlternate.rawValue != 0 }
    public var hasControl: Bool { modifiers & CGEventFlags.maskControl.rawValue != 0 }

    /// True when this chord carries at least one modifier. A bare key would
    /// swallow ordinary typing system-wide, so the recorder refuses one.
    public var hasAnyModifier: Bool { modifiers != 0 }

    // MARK: Matching

    /// Matches a live event. Both sides are normalised, so a chord recorded with
    /// the left Command key fires on the right one too.
    public func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && modifiers == Shortcut.normalise(flags: flags.rawValue)
    }

    // MARK: Display

    /// Cocoa-style rendering, modifiers in Apple's canonical order: ⌃⌥⇧⌘.
    public var displayString: String {
        var s = ""
        if hasControl { s += "⌃" }
        if hasOption { s += "⌥" }
        if hasShift { s += "⇧" }
        if hasCommand { s += "⌘" }
        return s + Shortcut.keyName(for: keyCode)
    }

    /// Human-readable name for a virtual key code. Covers the keys a user is
    /// plausibly going to bind; anything exotic falls back to its number so the
    /// UI never renders an empty chord.
    public static func keyName(for keyCode: UInt16) -> String {
        if let named = specialKeyNames[keyCode] { return named }
        if let letter = letterKeyNames[keyCode] { return letter }
        return "Key \(keyCode)"
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩",        // Return
        48: "⇥",        // Tab
        49: "Space",
        51: "⌫",        // Delete
        53: "⎋",        // Escape
        76: "⌤",        // Enter (keypad)
        117: "⌦",       // Forward delete
        115: "↖",       // Home
        119: "↘",       // End
        116: "⇞",       // Page up
        121: "⇟",       // Page down
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20"
    ]

    private static let letterKeyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/", 42: "\\", 50: "`"
    ]
}
