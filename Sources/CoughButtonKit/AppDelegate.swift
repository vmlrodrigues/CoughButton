import AppKit

// ---------------------------------------------------------------------------
// AppDelegate — wiring only. Every piece it owns is independently testable;
// this just holds them together and manages the launch-time permission gate.
// ---------------------------------------------------------------------------

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = SettingsStore()
    private let meeting = MeetingController()
    private let updater = Updater()

    private var hotkeys: HotkeyEngine?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let engine = HotkeyEngine { [weak self] action, phase in
            Task { @MainActor in self?.meeting.perform(action, phase: phase) }
        }
        engine.update(bindings: settings.allBindings)
        hotkeys = engine

        let model = SettingsViewModel(
            store: settings,
            onRecordingChange: { [weak self] recording in
                self?.hotkeys?.isSuspended = recording
            },
            onChange: { [weak self] in
                guard let self else { return }
                self.hotkeys?.update(bindings: self.settings.allBindings)
            }
        )
        settingsWindow = SettingsWindowController(model: model)

        let status = StatusItemController(controller: meeting)
        status.onOpenSettings = { [weak self] in self?.settingsWindow?.show() }
        status.onQuit = { NSApp.terminate(nil) }
        statusItem = status

        meeting.start()
        updater.start()

        // Ask once at launch. If it's already granted this is a no-op; if not,
        // the settings window carries a persistent prompt, so a user who
        // dismisses the system dialog is not left without a route back.
        if !AX.isTrusted {
            AX.requestTrust()
            settingsWindow?.show()
        }
        engine.start()
    }

    /// An agent app has no visible menu bar, but without a main menu AppKit has
    /// nothing to dispatch key equivalents against — so ⌘W simply does nothing
    /// in the settings window, and neither does ⌘Q. The menu is never drawn;
    /// it exists purely so those shortcuts resolve.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(openSettings),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CoughButton",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Standard editing verbs, so text selection in the settings window
        // behaves the way every other Mac app does.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimise",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Releases any held push-to-talk before going away, so quitting mid-hold
        // can never strand the mic open.
        hotkeys?.stop()
        meeting.stop()
    }
}
