import Cocoa
import ApplicationServices

// axctl — probe harness for driving/reading Teams via AX while it is NOT frontmost.
//
//   axctl find <substring>            list matching nodes (role, value, actions, path)
//   axctl press <substring>           AXPress the first match
//   axctl state <substring>           print value of every match (fast re-read)
//   axctl key <keycode> <mods>        CGEventPostToPid to Teams (background keystroke)
//   axctl keyglobal <keycode> <mods>  CGEventPost to HID tap (goes to frontmost app)
//   axctl front <bundleid>            activate an app
//   axctl frontmost                   report frontmost app
//   axctl bench                       time a full tree walk
//
// mods: comma list of cmd,shift,opt,ctrl

let BUNDLE = ProcessInfo.processInfo.environment["AXCTL_BUNDLE"] ?? "com.microsoft.teams2"

func teamsPid() -> pid_t? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == BUNDLE }?.processIdentifier
}

func attr(_ el: AXUIElement, _ name: String) -> Any? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}
func s(_ el: AXUIElement, _ n: String) -> String? { attr(el, n) as? String }
func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func acts(_ el: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyActionNames(el, &v) == .success else { return [] }
    return (v as? [String]) ?? []
}

struct Hit { let el: AXUIElement; let label: String; let role: String; let value: String; let actions: [String]; let path: String }

func label(_ el: AXUIElement) -> String {
    let t = s(el, kAXTitleAttribute) ?? ""
    let d = s(el, kAXDescriptionAttribute) ?? ""
    let h = s(el, kAXHelpAttribute) ?? ""
    return [t, d, h].filter { !$0.isEmpty }.joined(separator: " | ")
}
func valueStr(_ el: AXUIElement) -> String {
    if let v = attr(el, kAXValueAttribute) {
        if let n = v as? NSNumber { return n.stringValue }
        if let str = v as? String { return str }
        return "\(v)"
    }
    return ""
}

func walk(_ el: AXUIElement, needle: String, depth: Int, path: String, out: inout [Hit], budget: inout Int) {
    budget -= 1
    if budget < 0 || depth > 40 { return }
    let lab = label(el)
    let role = s(el, kAXRoleAttribute) ?? "?"
    let dom = s(el, "AXDOMIdentifier") ?? ""
    let here = path.isEmpty ? role : "\(path)/\(role)"
    if !needle.isEmpty,
       lab.localizedCaseInsensitiveContains(needle) || dom.localizedCaseInsensitiveContains(needle) {
        out.append(Hit(el: el, label: lab, role: role + (s(el, kAXSubroleAttribute).map { "[\($0)]" } ?? ""),
                       value: valueStr(el), actions: acts(el), path: here + (dom.isEmpty ? "" : " dom#\(dom)")))
    }
    for c in kids(el) { walk(c, needle: needle, depth: depth + 1, path: here, out: &out, budget: &budget) }
}

func search(_ needle: String) -> [Hit] {
    guard let pid = teamsPid() else { print("teams not running"); exit(1) }
    let app = AXUIElementCreateApplication(pid)
    var out: [Hit] = []
    var budget = 60000
    walk(app, needle: needle, depth: 0, path: "", out: &out, budget: &budget)
    return out
}

func modFlags(_ str: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in str.split(separator: ",") {
        switch m.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cmd", "command": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "opt", "option", "alt": f.insert(.maskAlternate)
        case "ctrl", "control": f.insert(.maskControl)
        default: break
        }
    }
    return f
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { print("no command"); exit(2) }

switch cmd {
case "find", "state":
    let needle = argv.count > 1 ? argv[1] : ""
    let t0 = Date()
    let hits = search(needle)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    print("// \(hits.count) hit(s) for \(needle.debugDescription) in \(ms)ms")
    for h in hits {
        print("\(h.role)  value=\(h.value.debugDescription)  label=\(h.label.debugDescription)")
        if cmd == "find" { print("    actions=\(h.actions.joined(separator: ",")))  path=\(h.path)") }
    }

case "press":
    let needle = argv[1]
    let idx = argv.count > 2 ? (Int(argv[2]) ?? 0) : 0
    let hits = search(needle)
    guard idx < hits.count else { print("no match[\(idx)] for \(needle) (\(hits.count) hits)"); exit(1) }
    let h = hits[idx]
    print("pressing: \(h.role) \(h.label.debugDescription) (value=\(h.value))")
    let t0 = Date()
    let err = AXUIElementPerformAction(h.el, kAXPressAction as CFString)
    print("AXPress -> \(err.rawValue) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")

case "key", "keyglobal":
    guard let pid = teamsPid() else { print("teams not running"); exit(1) }
    let code = CGKeyCode(UInt16(argv[1])!)
    let flags = argv.count > 2 ? modFlags(argv[2]) : []
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
    down.flags = flags; up.flags = flags
    if cmd == "key" {
        down.postToPid(pid); usleep(30000); up.postToPid(pid)
        print("posted keycode \(code) flags=\(flags.rawValue) -> pid \(pid)")
    } else {
        down.post(tap: .cghidEventTap); usleep(30000); up.post(tap: .cghidEventTap)
        print("posted keycode \(code) flags=\(flags.rawValue) -> HID tap (frontmost)")
    }

case "front":
    let bid = argv[1]
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else {
        print("not running: \(bid)"); exit(1)
    }
    app.activate(options: [])
    usleep(400000)
    print("activated \(bid); frontmost is now \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")

case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")

case "bench":
    let t0 = Date()
    let hits = search("zzz-no-match-zzz")
    _ = hits
    print("full tree walk: \(Int(Date().timeIntervalSince(t0) * 1000))ms")

default:
    print("unknown command \(cmd)"); exit(2)
}
