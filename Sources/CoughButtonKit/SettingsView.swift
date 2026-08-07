import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// SettingsView — shortcut binding, permission status, and the few options that
// earn their place in a first release.
// ---------------------------------------------------------------------------

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var bindings: [HotkeyBinding] = []
    @Published public var accessibilityGranted = AX.isTrusted
    @Published public var launchAtLogin = LoginItem.isEnabled
    /// Action → the action it collides with, shown inline under the row.
    @Published public var conflicts: [HotkeyAction: HotkeyAction] = [:]

    private let store: SettingsStore
    private let onChange: () -> Void
    private let onRecordingChange: (Bool) -> Void
    private var timer: Timer?

    public init(
        store: SettingsStore,
        onRecordingChange: @escaping (Bool) -> Void,
        onChange: @escaping () -> Void
    ) {
        self.store = store
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
        self.bindings = store.allBindings
    }

    public func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessibilityGranted = AX.isTrusted
                self.launchAtLogin = LoginItem.isEnabled
            }
        }
    }

    public func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    public func shortcut(for action: HotkeyAction) -> Shortcut? {
        bindings.first { $0.action == action }?.shortcut
    }

    public func set(_ shortcut: Shortcut?, for action: HotkeyAction) {
        if let shortcut, let clash = store.conflict(for: shortcut, excluding: action) {
            conflicts[action] = clash
            return
        }
        conflicts[action] = nil
        store.setShortcut(shortcut, for: action)
        bindings = store.allBindings
        onChange()
    }

    public func resetToDefaults() {
        store.resetToDefaults()
        conflicts.removeAll()
        bindings = store.allBindings
        onChange()
    }

    public func setRecording(_ recording: Bool) { onRecordingChange(recording) }

    public func toggleLaunchAtLogin() {
        LoginItem.toggle()
        launchAtLogin = LoginItem.isEnabled
    }
}

public struct SettingsView: View {
    @ObservedObject private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                header
            }

            if !model.accessibilityGranted {
                Section {
                    accessibilityWarning
                }
            }

            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    shortcutRow(action)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Shortcuts work while Teams is in the background. Press Delete while recording to unbind, Escape to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Start at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLaunchAtLogin() }
                ))
            }

            Section {
                HStack {
                    Button("Restore Defaults") { model.resetToDefaults() }
                    Spacer()
                    Button("Check for Updates…") { Updater.checkNowUserInitiated() }
                }
            } footer: {
                Text("Works with Microsoft Teams.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 460)
        .onAppear { model.startWatching() }
        .onDisappear { model.stopWatching() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("CoughButton")
                    .font(.title3.weight(.semibold))
                Text("Version \(Updater.currentVersion())")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility access required")
                    .fontWeight(.semibold)
                Text("CoughButton reads and presses Teams' own meeting controls. Without this permission it can't see or change your mic or camera.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings…") { AX.openAccessibilitySettings() }
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func shortcutRow(_ action: HotkeyAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                    Text(action.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ShortcutRecorder(
                    shortcut: model.shortcut(for: action),
                    onRecordingChange: { model.setRecording($0) },
                    onChange: { model.set($0, for: action) }
                )
                .frame(width: 150, height: 24)
            }
            if let clash = model.conflicts[action] {
                Text("Already used by “\(clash.title)”.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Window

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsViewModel

    /// AppKit persists the frame under this key; we read it directly to tell a
    /// first run from a restored one.
    private static let autosaveName = "CoughButtonSettings"
    private static var frameDefaultsKey: String { "NSWindow Frame \(autosaveName)" }

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "CoughButton Settings"
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.isReleasedWhenClosed = false

        // Remember where the user dragged it. `setFrameAutosaveName` restores a
        // saved frame straight away, so only centre when there isn't one —
        // otherwise every launch would yank the window back to the middle.
        let hasSavedFrame = UserDefaults.standard.object(forKey: Self.frameDefaultsKey) != nil
        newWindow.setFrameAutosaveName(Self.autosaveName)
        if !hasSavedFrame { newWindow.center() }

        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }
}
