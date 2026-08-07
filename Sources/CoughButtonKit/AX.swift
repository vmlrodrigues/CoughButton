import Foundation
import ApplicationServices
import AppKit

// ---------------------------------------------------------------------------
// AX — a thin, non-throwing wrapper over the C Accessibility API.
//
// Everything here is a direct AXUIElement call; the interesting decisions live
// in MeetingClient/TeamsAXClient. Kept separate so those can be reasoned about
// (and tested) without this layer in the way.
// ---------------------------------------------------------------------------

public enum AX {

    // MARK: Permission

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant Accessibility access" prompt once. macOS only
    /// surfaces it while the app is unsigned-or-newly-installed; thereafter the
    /// user must go to System Settings, which `openAccessibilitySettings` does.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Attribute reads

    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    public static func windows(ofPID pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        return (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Web content exposes its DOM `id` here — the most stable handle we get.
    public static func domIdentifier(_ element: AXUIElement) -> String? {
        string(element, "AXDOMIdentifier")
    }

    /// The user-visible label. Teams puts the control's *action* in the
    /// description ("Mute mic"), which is what we read state from.
    public static func label(_ element: AXUIElement) -> String? {
        if let d = string(element, kAXDescriptionAttribute), !d.isEmpty { return d }
        if let t = string(element, kAXTitleAttribute), !t.isEmpty { return t }
        return nil
    }

    /// `true` when the reference has been invalidated by a re-render, which is
    /// the signal to go and find the element again.
    public static func isStale(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            == .invalidUIElement
    }

    // MARK: Actions

    @discardableResult
    public static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // MARK: Search

    /// Depth-first search for the first descendant satisfying `predicate`.
    ///
    /// `maxDepth` matters: Teams' meeting toolbar sits ~20 levels down, but an
    /// unbounded walk on a big tree is measurably slower, so callers cap it.
    /// `budget` is a hard ceiling on nodes visited — a runaway guard for trees
    /// that are re-rendering underneath us.
    public static func firstDescendant(
        of root: AXUIElement,
        maxDepth: Int = 40,
        budget: Int = 20_000,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var remaining = budget
        return search(root, depth: 0, maxDepth: maxDepth, remaining: &remaining, predicate)
    }

    private static func search(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        remaining: inout Int,
        _ predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if remaining <= 0 || depth > maxDepth { return nil }
        remaining -= 1
        if predicate(element) { return element }
        for child in children(element) {
            if let hit = search(child, depth: depth + 1, maxDepth: maxDepth, remaining: &remaining, predicate) {
                return hit
            }
        }
        return nil
    }
}
