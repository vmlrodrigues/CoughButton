import Foundation
import CoreGraphics

// ---------------------------------------------------------------------------
// Settings — the four bindable actions and their persistence.
//
// The store takes a UserDefaults instance so tests can hand it a scratch suite
// instead of touching the real preferences domain.
// ---------------------------------------------------------------------------

public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case toggleMic
    case toggleCamera
    case raiseHand
    case pushToTalk

    public var title: String {
        switch self {
        case .toggleMic: return "Mute / unmute"
        case .toggleCamera: return "Camera on / off"
        case .raiseHand: return "Raise / lower hand"
        case .pushToTalk: return "Push to talk"
        }
    }

    public var subtitle: String {
        switch self {
        case .toggleMic: return "Toggles your microphone in the meeting."
        case .toggleCamera: return "Toggles your camera in the meeting."
        case .raiseHand: return "Raises or lowers your hand."
        case .pushToTalk: return "Hold to talk, release to go back on mute."
        }
    }

    /// Push-to-talk is momentary; the rest fire once per press.
    public var isMomentary: Bool { self == .pushToTalk }

    /// Chosen to sit in one obvious family (⌃⌥⌘ + a mnemonic letter) and to
    /// avoid every default macOS binding. All four are user-rebindable.
    public var defaultShortcut: Shortcut {
        let base = CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
        switch self {
        case .toggleMic: return Shortcut(keyCode: 46, modifiers: base)     // M
        case .toggleCamera: return Shortcut(keyCode: 9, modifiers: base)   // V
        case .raiseHand: return Shortcut(keyCode: 4, modifiers: base)      // H
        case .pushToTalk: return Shortcut(keyCode: 49, modifiers: base)    // Space
        }
    }
}

public struct HotkeyBinding: Equatable, Sendable {
    public var action: HotkeyAction
    /// `nil` means the user cleared the binding — the action stays available
    /// from the menu but has no hotkey.
    public var shortcut: Shortcut?

    public init(action: HotkeyAction, shortcut: Shortcut?) {
        self.action = action
        self.shortcut = shortcut
    }
}

public final class SettingsStore {
    private let defaults: UserDefaults
    private static func key(_ a: HotkeyAction) -> String { "shortcut.\(a.rawValue)" }
    private static let clearedKey = "shortcut.cleared"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Read / write

    public func shortcut(for action: HotkeyAction) -> Shortcut? {
        if clearedActions().contains(action.rawValue) { return nil }
        guard let data = defaults.data(forKey: Self.key(action)),
              let decoded = try? JSONDecoder().decode(Shortcut.self, from: data)
        else { return action.defaultShortcut }
        return decoded
    }

    public func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        var cleared = clearedActions()
        if let shortcut {
            cleared.remove(action.rawValue)
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: Self.key(action))
        } else {
            cleared.insert(action.rawValue)
            defaults.removeObject(forKey: Self.key(action))
        }
        defaults.set(Array(cleared), forKey: Self.clearedKey)
    }

    public func resetToDefaults() {
        for action in HotkeyAction.allCases { defaults.removeObject(forKey: Self.key(action)) }
        defaults.removeObject(forKey: Self.clearedKey)
    }

    public var allBindings: [HotkeyBinding] {
        HotkeyAction.allCases.map { HotkeyBinding(action: $0, shortcut: shortcut(for: $0)) }
    }

    private func clearedActions() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.clearedKey) ?? [])
    }

    // MARK: Conflicts

    /// The action, if any, already bound to `shortcut` — ignoring `action`
    /// itself so re-recording the same chord onto the same row isn't a clash.
    public func conflict(for shortcut: Shortcut, excluding action: HotkeyAction) -> HotkeyAction? {
        HotkeyAction.allCases.first { candidate in
            candidate != action && self.shortcut(for: candidate) == shortcut
        }
    }
}
