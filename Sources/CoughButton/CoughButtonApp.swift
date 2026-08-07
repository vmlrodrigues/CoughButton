import AppKit
import CoughButtonKit

// An @main struct rather than a main.swift: top-level code in main.swift is not
// main-actor isolated, so every AppKit call from it trips actor-isolation
// checking. `@MainActor static func main()` gives the entry point the isolation
// AppKit actually requires.
@main
struct CoughButtonApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared

        // Headless dev mode: render every menu-bar state to a contact sheet so
        // the glyphs can be judged side by side instead of one at a time in the
        // menu bar. Never reached in normal use.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-status-icons"), flag + 1 < args.count {
            app.setActivationPolicy(.prohibited)
            StatusIconDump.run(outputDir: args[flag + 1])
            return
        }

        // Held for the lifetime of the process: NSApplication.delegate is weak,
        // and main() does not return until the app quits.
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar agent: no Dock icon, no main window. Matches LSUIElement in
        // Info.plist, and also covers `swift run`, where there is no bundle.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
