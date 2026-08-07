import Cocoa
import ApplicationServices

// Does Teams' WebView2 push AX notifications, or must we poll?
// Registers on the app element + a specific web toggle, then flips the toggle
// from inside this same process and logs anything that arrives.

let BUNDLE = "com.microsoft.teams2"
let NEEDLE = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Unread (⌥ ⌘ U)"

func attr(_ el: AXUIElement, _ n: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success else { return nil }
    return v
}
func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func label(_ el: AXUIElement) -> String {
    [(attr(el, kAXTitleAttribute) as? String) ?? "", (attr(el, kAXDescriptionAttribute) as? String) ?? ""]
        .filter { !$0.isEmpty }.joined(separator: " | ")
}

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == BUNDLE }) else {
    print("teams not running"); exit(1)
}
let pid = app.processIdentifier
let appEl = AXUIElementCreateApplication(pid)

// locate target
var target: AXUIElement?
func find(_ el: AXUIElement, _ d: Int) {
    if target != nil || d > 40 { return }
    if (attr(el, kAXRoleAttribute) as? String) == "AXCheckBox", label(el).contains(NEEDLE) { target = el; return }
    for c in kids(el) { find(c, d + 1) }
}
find(appEl, 0)
guard let tgt = target else { print("target not found: \(NEEDLE)"); exit(1) }
print("target: \(label(tgt))  value=\(attr(tgt, kAXValueAttribute) ?? "nil")")

var observer: AXObserver?
let cb: AXObserverCallback = { _, element, notification, _ in
    let n = notification as String
    let lab = label(element)
    let v = attr(element, kAXValueAttribute)
    print("  ⚡️ \(n)  element=\(lab.isEmpty ? "<unlabelled>" : lab)  value=\(v ?? "nil")")
}
guard AXObserverCreate(pid, cb, &observer) == .success, let obs = observer else {
    print("AXObserverCreate failed"); exit(1)
}

let appLevel = [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification,
                kAXUIElementDestroyedNotification, kAXLayoutChangedNotification,
                "AXLiveRegionChanged", kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification]
for n in appLevel {
    let e = AXObserverAddNotification(obs, appEl, n as CFString, nil)
    print("register app-level \(n) -> \(e.rawValue)")
}
for n in [kAXValueChangedNotification, kAXTitleChangedNotification] {
    let e = AXObserverAddNotification(obs, tgt, n as CFString, nil)
    print("register element-level \(n) -> \(e.rawValue)")
}

CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

print("--- flipping the toggle in 1.0s, listening for 4s ---")
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    let e = AXUIElementPerformAction(tgt, kAXPressAction as CFString)
    print("  (AXPress -> \(e.rawValue))")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
    // flip it back so we leave state as we found it
    let e = AXUIElementPerformAction(tgt, kAXPressAction as CFString)
    print("  (AXPress restore -> \(e.rawValue))")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
    print("--- done; final value=\(attr(tgt, kAXValueAttribute) ?? "nil") ---")
    exit(0)
}
CFRunLoopRun()
