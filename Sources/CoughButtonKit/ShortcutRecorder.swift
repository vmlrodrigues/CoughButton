import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// ShortcutRecorderView — click, press a chord, done.
//
// Two AppKit details make this less trivial than it looks:
//
//  • Any chord containing ⌘ is delivered as a *key equivalent*, not a keyDown,
//    so `performKeyEquivalent` has to be overridden or ⌘-shortcuts can never be
//    recorded — which would be most of them.
//  • The global event tap has to be suspended while recording, or pressing
//    ⌃⌥⌘M to rebind mute would also toggle the mic.
//
// Escape cancels, Delete unbinds, and a chord with no modifier is refused —
// binding a bare key globally would swallow ordinary typing everywhere.
// ---------------------------------------------------------------------------

public final class ShortcutRecorderView: NSView {

    public var shortcut: Shortcut? { didSet { needsDisplay = true } }
    public var onChange: ((Shortcut?) -> Void)?
    /// Called with `true` when recording starts and `false` when it stops, so
    /// the owner can suspend global hotkeys for the duration.
    public var onRecordingChange: ((Bool) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            onRecordingChange?(isRecording)
        }
    }
    private var rejection: String?

    public override var acceptsFirstResponder: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    // MARK: Interaction

    public override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            rejection = nil
            isRecording = true
        }
    }

    public override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return true
    }

    private func stopRecording() {
        isRecording = false
        rejection = nil
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return capture(event)
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording, capture(event) else {
            super.keyDown(with: event)
            return
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
        super.flagsChanged(with: event)
    }

    private func capture(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:                       // Escape — leave the binding as it was
            stopRecording()
            return true
        case 51, 117:                  // Delete / forward delete — unbind
            shortcut = nil
            onChange?(nil)
            stopRecording()
            return true
        default:
            break
        }

        // NSEvent.ModifierFlags and CGEventFlags share bit positions for the
        // four modifiers we care about, so the raw value carries straight over.
        let candidate = Shortcut(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue))
        guard candidate.hasAnyModifier else {
            rejection = "Add a modifier"
            needsDisplay = true
            return true
        }
        shortcut = candidate
        onChange?(candidate)
        stopRecording()
        return true
    }

    // MARK: Accessibility
    //
    // A custom NSView is invisible to VoiceOver unless it says otherwise, and an
    // app built on the Accessibility API has no business shipping a control that
    // screen readers can't see.

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? { "Keyboard shortcut" }
    public override func accessibilityValue() -> Any? {
        if isRecording { return "Recording — press a shortcut" }
        return shortcut?.displayString ?? "Not set"
    }
    public override func accessibilityHelp() -> String? {
        "Activate, then press a key combination. Delete unbinds, Escape cancels."
    }
    public override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        isRecording = true
        return true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let colour: NSColor
        if let rejection {
            text = rejection
            colour = .systemOrange
        } else if isRecording {
            let live = Shortcut(keyCode: 0, modifiers: UInt64(NSEvent.modifierFlags.rawValue))
            let mods = live.displayString.replacingOccurrences(of: "A", with: "")
            text = mods.isEmpty ? "Press a shortcut…" : mods + "…"
            colour = .controlAccentColor
        } else if let shortcut {
            text = shortcut.displayString
            colour = .labelColor
        } else {
            text = "Click to record"
            colour = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .medium : .regular),
            .foregroundColor: colour
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

// MARK: - SwiftUI wrapper

public struct ShortcutRecorder: NSViewRepresentable {
    private let shortcut: Shortcut?
    private let onChange: (Shortcut?) -> Void
    private let onRecordingChange: (Bool) -> Void

    public init(
        shortcut: Shortcut?,
        onRecordingChange: @escaping (Bool) -> Void = { _ in },
        onChange: @escaping (Shortcut?) -> Void
    ) {
        self.shortcut = shortcut
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
    }

    public func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.shortcut = shortcut
        view.onChange = onChange
        view.onRecordingChange = onRecordingChange
        return view
    }

    public func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
        view.onRecordingChange = onRecordingChange
    }
}
