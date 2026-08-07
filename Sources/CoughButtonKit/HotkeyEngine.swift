import Foundation
import CoreGraphics
import AppKit

// ---------------------------------------------------------------------------
// HotkeyEngine — global hotkeys via a CGEventTap.
//
// An event tap rather than RegisterEventHotKey because push-to-talk needs
// key-*up*, which the Carbon API does not deliver. The tap needs Accessibility
// permission, which this app requires anyway, so it costs nothing extra.
//
// Two things here are easy to get wrong and are handled deliberately:
//
//  • Key-up is matched on the key code ALONE, not the full chord. Releasing
//    ⌃⌥⌘Space almost always lifts a modifier first, so the key-up arrives with
//    different flags than the key-down. Matching the chord again would strand
//    push-to-talk in the "held" state and leave the mic open.
//  • macOS silently disables a tap that takes too long. `.tapDisabledByTimeout`
//    is re-enabled rather than left dead, which would look like the app simply
//    stopped responding to its hotkeys.
// ---------------------------------------------------------------------------

public final class HotkeyEngine {

    public typealias Handler = (HotkeyAction, HotkeyPhase) -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [(action: HotkeyAction, shortcut: Shortcut)] = []
    /// Momentary actions currently held down, keyed by key code so key-up can be
    /// matched without the modifiers.
    private var held: [UInt16: HotkeyAction] = [:]
    private let handler: Handler

    /// Set while the settings window is recording a chord, so that pressing
    /// ⌃⌥⌘M to rebind it doesn't also fire the mute action.
    public var isSuspended = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stopTap() }

    // MARK: Bindings

    public func update(bindings newBindings: [HotkeyBinding]) {
        bindings = newBindings.compactMap { binding in
            guard let shortcut = binding.shortcut else { return nil }
            return (binding.action, shortcut)
        }
    }

    // MARK: Lifecycle

    /// Returns false when the tap could not be created — almost always missing
    /// Accessibility permission.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            NSLog("CoughButton: could not create event tap (Accessibility permission?)")
            return false
        }

        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    public func stop() {
        // Never leave a held push-to-talk dangling — that would keep the mic open.
        releaseAllHeld()
        stopTap()
    }

    private func stopTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    private func releaseAllHeld() {
        for (_, action) in held { handler(action, .ended) }
        held.removeAll()
    }

    // MARK: Event handling

    /// Returns true when the event was consumed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .keyDown:
            if isSuspended { return false }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Auto-repeat while a key is held would re-fire a toggle continuously.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return held[keyCode] != nil || matchingAction(keyCode: keyCode, flags: event.flags) != nil
            }
            guard let action = matchingAction(keyCode: keyCode, flags: event.flags) else { return false }
            if action.isMomentary { held[keyCode] = action }
            handler(action, .began)
            return true

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let action = held.removeValue(forKey: keyCode) else { return false }
            handler(action, .ended)
            return true

        default:
            return false
        }
    }

    private func matchingAction(keyCode: UInt16, flags: CGEventFlags) -> HotkeyAction? {
        bindings.first { $0.shortcut.matches(keyCode: keyCode, flags: flags) }?.action
    }
}

// C callbacks cannot capture context, so the engine arrives via `refcon`.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<HotkeyEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
