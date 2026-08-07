import Cocoa
import ApplicationServices

// Usage: axdump [--manual] [--maxdepth N] [--bundle com.microsoft.teams2]
var enableManual = false
var maxDepth = 12
var bundleID = "com.microsoft.teams2"
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--manual": enableManual = true
    case "--maxdepth": i += 1; maxDepth = Int(args[i]) ?? 12
    case "--bundle": i += 1; bundleID = args[i]
    default: break
    }
    i += 1
}

func attr(_ el: AXUIElement, _ name: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    attr(el, name) as? String
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func actions(_ el: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyActionNames(el, &v) == .success else { return [] }
    return (v as? [String]) ?? []
}

var nodeCount = 0

func dump(_ el: AXUIElement, depth: Int, path: String) {
    nodeCount += 1
    if nodeCount > 20000 { return }
    let pad = String(repeating: "  ", count: depth)
    let role = str(el, kAXRoleAttribute) ?? "?"
    let sub = str(el, kAXSubroleAttribute)
    let title = str(el, kAXTitleAttribute)
    let desc = str(el, kAXDescriptionAttribute)
    let help = str(el, kAXHelpAttribute)
    let value = attr(el, kAXValueAttribute)
    let ident = str(el, "AXDOMIdentifier")
    let cls = str(el, "AXDOMClassList")
    let acts = actions(el)

    var line = "\(pad)\(role)"
    if let s = sub { line += "[\(s)]" }
    if let t = title, !t.isEmpty { line += " title=\(t.prefix(90).debugDescription)" }
    if let d = desc, !d.isEmpty { line += " desc=\(d.prefix(90).debugDescription)" }
    if let h = help, !h.isEmpty { line += " help=\(h.prefix(90).debugDescription)" }
    if let v = value as? String, !v.isEmpty { line += " value=\(v.prefix(60).debugDescription)" }
    else if let v = value as? NSNumber { line += " value=\(v)" }
    if let id = ident, !id.isEmpty { line += " dom#\(id)" }
    if let c = cls, !c.isEmpty { line += " class=\(c.prefix(60))" }
    if !acts.isEmpty { line += " actions=\(acts.joined(separator: ","))" }
    print(line)

    guard depth < maxDepth else {
        let n = children(el).count
        if n > 0 { print("\(pad)  …\(n) more children (depth cap)") }
        return
    }
    for c in children(el) { dump(c, depth: depth + 1, path: path) }
}

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
    print("not running: \(bundleID)"); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)

if enableManual {
    // Chromium/WebView2 lazily builds its a11y tree. These two attributes are the
    // documented ways to force it on for a non-VoiceOver client.
    let r1 = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let r2 = AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    print("// set AXManualAccessibility -> \(r1.rawValue), AXEnhancedUserInterface -> \(r2.rawValue)")
    Thread.sleep(forTimeInterval: 1.5)
}

print("// pid=\(app.processIdentifier) bundle=\(bundleID) maxDepth=\(maxDepth)")
dump(ax, depth: 0, path: "")
print("// nodes visited: \(nodeCount)")
