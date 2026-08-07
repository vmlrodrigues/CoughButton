import AppKit

// ---------------------------------------------------------------------------
// StatusIconDump — renders every menu-bar state to a contact sheet.
//
//   CoughButton --render-status-icons <dir>
//
// A menu-bar glyph is 16pt of dark-on-light and light-on-dark that has to read
// in peripheral vision. Eyeballing it in the menu bar one state at a time is a
// bad way to design it; this puts every state side by side on both backgrounds,
// at actual size and magnified.
// ---------------------------------------------------------------------------

public enum StatusIconDump {

    private static let states: [(String, MeetingSnapshot)] = [
        ("idle", .idle),
        ("muted\ncam off", MeetingSnapshot(inMeeting: true, mic: .off, camera: .off, hand: .off)),
        ("LIVE\ncam off", MeetingSnapshot(inMeeting: true, mic: .on, camera: .off, hand: .off)),
        ("muted\ncam on", MeetingSnapshot(inMeeting: true, mic: .off, camera: .on, hand: .off)),
        ("LIVE\ncam on", MeetingSnapshot(inMeeting: true, mic: .on, camera: .on, hand: .off)),
        ("hand up", MeetingSnapshot(inMeeting: true, mic: .off, camera: .off, hand: .on)),
        ("unknown", MeetingSnapshot(inMeeting: true, mic: .unknown, camera: .unknown, hand: .off)),
        ("no perm", MeetingSnapshot(accessibilityGranted: false))
    ]

    /// Reproduces the menu bar's own template tinting for the contact sheet.
    private static func tinted(_ image: NSImage, _ colour: NSColor) -> NSImage {
        let copy = NSImage(size: image.size)
        copy.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        colour.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }

    public static func run(outputDir: String) {
        let cell: CGFloat = 130
        let barHeight: CGFloat = 24
        let zoom: CGFloat = 4
        let zoomRow: CGFloat = 40 * zoom / 4 * 2.2
        let rowHeight = barHeight + zoomRow + 42
        let width = cell * CGFloat(states.count)
        let height = rowHeight * 2 + 30

        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()

        // Two panels: menu bar in light appearance, and in dark.
        let panels: [(name: String, bg: NSColor, appearance: NSAppearance?)] = [
            ("Light menu bar", NSColor(calibratedWhite: 0.93, alpha: 1), NSAppearance(named: .aqua)),
            ("Dark menu bar", NSColor(calibratedWhite: 0.13, alpha: 1), NSAppearance(named: .darkAqua))
        ]

        for (panelIndex, panel) in panels.enumerated() {
            let panelBottom = height - rowHeight * CGFloat(panelIndex + 1)
            panel.bg.setFill()
            NSRect(x: 0, y: panelBottom, width: width, height: rowHeight).fill()

            let label = NSAttributedString(string: panel.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: panelIndex == 0 ? NSColor.black : NSColor.white
            ])
            label.draw(at: NSPoint(x: 8, y: panelBottom + rowHeight - 16))

            for (index, state) in states.enumerated() {
                let x = cell * CGFloat(index)
                // Render inside the panel's appearance so semantic colours
                // (labelColor, secondaryLabelColor) resolve for that mode.
                var image = NSImage()
                if let appearance = panel.appearance {
                    appearance.performAsCurrentDrawingAppearance {
                        image = StatusIcon.image(for: state.1)
                    }
                } else {
                    image = StatusIcon.image(for: state.1)
                }
                // A template image is a pure alpha mask — drawn as-is it is
                // solid black, which would be invisible on the dark panel and
                // would misrepresent what the menu bar actually shows. Tint it
                // the way macOS would.
                if image.isTemplate {
                    image = tinted(image, panelIndex == 0 ? .black : .white)
                }

                // Actual size, on the simulated bar.
                let actualY = panelBottom + rowHeight - 36
                image.draw(at: NSPoint(x: x + (cell - image.size.width) / 2, y: actualY),
                           from: .zero, operation: .sourceOver, fraction: 1)

                // Magnified.
                let zoomedWidth = image.size.width * zoom
                let zoomedHeight = image.size.height * zoom
                NSGraphicsContext.current?.imageInterpolation = .none
                image.draw(in: NSRect(x: x + (cell - zoomedWidth) / 2,
                                      y: panelBottom + 34,
                                      width: zoomedWidth, height: zoomedHeight),
                           from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.current?.imageInterpolation = .default

                let caption = NSAttributedString(string: state.0, attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: panelIndex == 0 ? NSColor.black : NSColor.white
                ])
                caption.draw(in: NSRect(x: x + 4, y: panelBottom + 4, width: cell - 8, height: 26))
            }
        }

        sheet.unlockFocus()

        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("status-icons.png")
        if let tiff = sheet.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}
