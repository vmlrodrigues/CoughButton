import Cocoa
import ApplicationServices

// How cheap is polling ONE cached element reference (vs the 200ms full tree walk)?
// And does a cached web-element reference stay valid over time / across re-renders?

let NEEDLE = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Unread (⌥ ⌘ U)"
let SECONDS = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 20

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

let pid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.microsoft.teams2" }!.processIdentifier
let appEl = AXUIElementCreateApplication(pid)

var target: AXUIElement?
func find(_ el: AXUIElement, _ d: Int) {
    if target != nil || d > 40 { return }
    if label(el).contains(NEEDLE), (attr(el, kAXRoleAttribute) as? String)?.contains("CheckBox") == true { target = el; return }
    for c in kids(el) { find(c, d + 1) }
}
let tFind = Date()
find(appEl, 0)
print("tree walk to find target: \(Int(Date().timeIntervalSince(tFind) * 1000))ms")
guard let tgt = target else { print("not found"); exit(1) }

// 1000 single-attribute reads off the cached reference
let t0 = Date()
var last: String = ""
for _ in 0..<1000 {
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(tgt, kAXValueAttribute as CFString, &v) == .success {
        last = "\(v ?? "nil" as CFTypeRef)"
    }
}
let per = Date().timeIntervalSince(t0) / 1000.0
print("cached-reference read: \(String(format: "%.3f", per * 1000))ms per read (1000 reads), last=\(last)")

// stability: does the reference survive over time?
print("--- polling cached reference once/sec for \(SECONDS)s (switch Teams tabs to force re-renders) ---")
for i in 1...SECONDS {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(tgt, kAXValueAttribute as CFString, &v)
    let lab = label(tgt)
    print("  t+\(i)s  err=\(err.rawValue)  value=\(v ?? "nil" as CFTypeRef)  label=\(lab.isEmpty ? "<GONE>" : lab)")
    Thread.sleep(forTimeInterval: 1.0)
}
