import Cocoa
import ApplicationServices

// Gate check: is the *calling* process trusted for Accessibility?
let trusted = AXIsProcessTrusted()
print("AXIsProcessTrusted() = \(trusted)")

// Who am I, from TCC's point of view?
print("pid            = \(ProcessInfo.processInfo.processIdentifier)")
print("executable     = \(ProcessInfo.processInfo.arguments[0])")
print("bundleID       = \(Bundle.main.bundleIdentifier ?? "<none>")")

// Find Teams
let apps = NSWorkspace.shared.runningApplications
let teams = apps.filter { ($0.bundleIdentifier ?? "").lowercased().contains("teams") }
print("--- Teams-ish processes ---")
for a in teams {
    print("  \(a.bundleIdentifier ?? "?")  pid=\(a.processIdentifier)  active=\(a.isActive)  name=\(a.localizedName ?? "?")")
}

// Can we actually read anything out of Teams?
if let main = teams.first(where: { $0.bundleIdentifier == "com.microsoft.teams2" }) {
    let ax = AXUIElementCreateApplication(main.processIdentifier)
    var value: CFArray?
    let err = AXUIElementCopyAttributeNames(ax, &value)
    print("--- AX probe on com.microsoft.teams2 ---")
    print("AXUIElementCopyAttributeNames -> \(err.rawValue) (\(err))")
    if let names = value as? [String] {
        print("attributes: \(names.joined(separator: ", "))")
    }
    var win: CFTypeRef?
    let werr = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &win)
    print("AXWindows -> \(werr.rawValue)  count=\((win as? [AXUIElement])?.count ?? -1)")
}
