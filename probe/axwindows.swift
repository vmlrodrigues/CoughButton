import Cocoa
import ApplicationServices

func attr(_ el: AXUIElement, _ n: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success else { return nil }
    return v
}

for app in NSWorkspace.shared.runningApplications
    where (app.bundleIdentifier ?? "").contains("teams") {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    print("\(app.bundleIdentifier ?? "?")  pid=\(app.processIdentifier)  windows=\(wins.count)  activationPolicy=\(app.activationPolicy.rawValue)")
    for (i, w) in wins.enumerated() {
        let t = (attr(w, kAXTitleAttribute) as? String) ?? "<untitled>"
        let sub = (attr(w, kAXSubroleAttribute) as? String) ?? "?"
        let pos = attr(w, kAXPositionAttribute)
        var p = CGPoint.zero
        if let pv = pos { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        print("   [\(i)] \(sub)  \(t.prefix(100).debugDescription)  at \(Int(p.x)),\(Int(p.y))")
    }
}
