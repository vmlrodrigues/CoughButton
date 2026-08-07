import AppKit

// ---------------------------------------------------------------------------
// StatusIcon — renders the menu-bar glyph from a MeetingSnapshot.
//
// Design rules, in priority order:
//
//  1. The resting state must look NATIVE. Muted with the camera off is what you
//     see 95% of the time, so it renders as a true template image: macOS tints
//     it exactly like every other menu-bar icon, in light mode, dark mode, when
//     the menu is open and under reduced transparency.
//  2. Colour means danger, and only danger. Red = you are transmitting.
//     Orange = we cannot confirm the state. Nothing else gets a colour, which
//     is why the raised hand is not blue.
//  3. Shape stays stable across states. "Unknown" is the same mic in orange
//     outline, NOT a question mark — an icon that changes into a different
//     symbol is unreadable at a glance and looks broken.
//  4. Glyph count carries meeting presence: one glyph = no meeting, two = in a
//     meeting. So the icon never has to jitter between widths to say something
//     it could say by shape.
// ---------------------------------------------------------------------------

public enum StatusIcon {

    private static let pointSize: CGFloat = 13
    private static let height: CGFloat = 16
    private static let gap: CGFloat = 2.5

    /// A glyph plus its tint. `nil` tint means "leave it to the template",
    /// which is what keeps the common case looking native.
    private struct Glyph {
        let name: String
        let tint: NSColor?
    }

    public static func image(for snapshot: MeetingSnapshot) -> NSImage {
        compose(glyphs(for: snapshot))
    }

    private static func glyphs(for snapshot: MeetingSnapshot) -> [Glyph] {
        guard snapshot.accessibilityGranted else {
            return [Glyph(name: "exclamationmark.triangle.fill", tint: .systemOrange)]
        }
        guard snapshot.inMeeting else {
            // Single outline glyph: quiet, clearly "nothing going on", and
            // distinct from the filled in-meeting muted state.
            return [Glyph(name: "mic.slash", tint: nil)]
        }

        // Filled = active, outline = inactive. The off states use outlines
        // because `video.slash.fill` is a solid rectangle that optically
        // swamps the mic sitting next to it — the pair has to read as a pair.
        var glyphs = [
            glyph(for: snapshot.mic, on: "mic.fill", off: "mic.slash", unknown: "mic"),
            glyph(for: snapshot.camera, on: "video.fill", off: "video.slash", unknown: "video")
        ]
        if snapshot.hand == .on {
            // Template, not a third colour — a raised hand is information, not a
            // warning.
            glyphs.append(Glyph(name: "hand.raised.fill", tint: nil))
        }
        return glyphs
    }

    private static func glyph(for state: ToggleState, on: String, off: String, unknown: String) -> Glyph {
        switch state {
        case .on: return Glyph(name: on, tint: .systemRed)
        case .off: return Glyph(name: off, tint: nil)
        case .unknown: return Glyph(name: unknown, tint: .systemOrange)
        }
    }

    // MARK: Drawing

    private static func compose(_ glyphs: [Glyph]) -> NSImage {
        // A single NSImage is either a template or it isn't — there is no
        // per-glyph mixing. If anything needs a colour, the untinted glyphs fall
        // back to labelColor, which still tracks light/dark.
        let isTemplate = glyphs.allSatisfy { $0.tint == nil }

        let rendered: [NSImage] = glyphs.compactMap { spec in
            guard let base = NSImage(systemSymbolName: spec.name, accessibilityDescription: nil) else { return nil }
            var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium, scale: .medium)
            if !isTemplate {
                config = config.applying(
                    NSImage.SymbolConfiguration(paletteColors: [spec.tint ?? .labelColor])
                )
            }
            return base.withSymbolConfiguration(config)
        }
        guard !rendered.isEmpty else { return NSImage(size: NSSize(width: 1, height: height)) }

        let width = rendered.reduce(0) { $0 + $1.size.width } + gap * CGFloat(rendered.count - 1)
        let image = NSImage(size: NSSize(width: max(width, 1), height: height))

        image.lockFocus()
        var x: CGFloat = 0
        for glyph in rendered {
            // Centre each glyph on the canvas rather than sitting them on a
            // shared baseline: SF Symbols carry differing internal padding, so
            // baseline alignment makes a slashed glyph sit visibly low next to
            // an unslashed one.
            let y = ((height - glyph.size.height) / 2).rounded()
            glyph.draw(at: NSPoint(x: x.rounded(), y: y),
                       from: .zero, operation: .sourceOver, fraction: 1)
            x += glyph.size.width + gap
        }
        image.unlockFocus()

        image.isTemplate = isTemplate
        return image
    }

    /// Short text for the menu header and tooltip, e.g. "Mic live · Camera off".
    public static func summary(for snapshot: MeetingSnapshot) -> String {
        guard snapshot.accessibilityGranted else { return "Accessibility permission needed" }
        guard snapshot.inMeeting else { return "No meeting detected" }
        return "\(describe(snapshot.mic, on: "Mic live", off: "Mic muted")) · "
            + describe(snapshot.camera, on: "Camera on", off: "Camera off")
    }

    private static func describe(_ state: ToggleState, on: String, off: String) -> String {
        switch state {
        case .on: return on
        case .off: return off
        case .unknown: return "State unknown"
        }
    }
}
