import AppKit
import Combine

// ---------------------------------------------------------------------------
// StatusItemController — the menu-bar item.
//
// AppKit NSStatusItem rather than SwiftUI's MenuBarExtra: MenuBarExtra is
// unreliable in a hand-assembled SwiftPM bundle (the same reason BarPilot
// avoids it). The settings UI is still SwiftUI, hosted in a window.
//
// The menu is rebuilt on open so its verbs track live state — "Mute" vs
// "Unmute" — rather than going stale between openings.
// ---------------------------------------------------------------------------

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let controller: MeetingController
    private var cancellables = Set<AnyCancellable>()

    public var onOpenSettings: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init(controller: MeetingController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.render(snapshot) }
            .store(in: &cancellables)

        render(controller.snapshot)
    }

    private func render(_ snapshot: MeetingSnapshot) {
        statusItem.button?.image = StatusIcon.image(for: snapshot)
        statusItem.button?.toolTip = "CoughButton — \(StatusIcon.summary(for: snapshot))"
    }

    // MARK: Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let snapshot = controller.snapshot
        menu.removeAllItems()

        let header = NSMenuItem(title: StatusIcon.summary(for: snapshot), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !snapshot.accessibilityGranted {
            menu.addItem(.separator())
            menu.addItem(item(title: "Grant Accessibility Access…", action: #selector(openAccessibility)))
        } else if snapshot.inMeeting {
            menu.addItem(.separator())
            menu.addItem(item(
                title: snapshot.mic == .on ? "Mute" : "Unmute",
                action: #selector(toggleMic)
            ))
            menu.addItem(item(
                title: snapshot.camera == .on ? "Turn Camera Off" : "Turn Camera On",
                action: #selector(toggleCamera)
            ))
            menu.addItem(item(
                title: snapshot.hand == .on ? "Lower Hand" : "Raise Hand",
                action: #selector(toggleHand)
            ))
        }

        menu.addItem(.separator())
        menu.addItem(item(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(item(title: "Check for Updates…", action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit CoughButton", action: #selector(quit), keyEquivalent: "q"))
    }

    private func item(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = self
        return menuItem
    }

    // MARK: Actions

    @objc private func toggleMic() { controller.perform(.toggleMic) }
    @objc private func toggleCamera() { controller.perform(.toggleCamera) }
    @objc private func toggleHand() { controller.perform(.raiseHand) }
    @objc private func openAccessibility() { AX.openAccessibilitySettings() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func checkForUpdates() { Updater.checkNowUserInitiated() }
    @objc private func quit() { onQuit?() }
}
