import AppKit
import Foundation

// ---------------------------------------------------------------------------
// icon-gen — draws the app icon concepts as PNGs.
//
// The icon lives in source rather than as an opaque binary so it can be tweaked
// and regenerated:  swift tools/icon-gen.swift <outputDir> [concept]
//
// Concepts: button | mic | micbutton | wave | all
// ---------------------------------------------------------------------------

let size: CGFloat = 1024
/// macOS icon artwork sits inside the canvas with a margin; the rounded-square
/// corner radius is ~22.4% of the artwork's edge.
let margin: CGFloat = size * 0.098
let artSize = size - margin * 2
let cornerRadius = artSize * 0.2237

// MARK: - Helpers

func makeImage(_ draw: (CGContext) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(ctx)
    image.unlockFocus()
    return image
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func artRect() -> CGRect {
    CGRect(x: margin, y: margin, width: artSize, height: artSize)
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The rounded-square plate every concept sits on.
func drawPlate(_ ctx: CGContext, top: CGColor, bottom: CGColor) {
    let rect = artRect()
    let path = roundedPath(rect, cornerRadius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.03,
                  color: rgb(0, 0, 0, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])
    // Soft top highlight, the standard macOS plate treatment.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.1),
                           options: [])
    ctx.restoreGState()
}

/// Glossy circular push button — the physical broadcast control.
func drawPushButton(_ ctx: CGContext, center: CGPoint, radius: CGFloat, lit: Bool) {
    // Bezel
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -radius * 0.06),
                  blur: radius * 0.18,
                  color: rgb(0, 0, 0, 0.55))
    ctx.setFillColor(rgb(28, 30, 34))
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    ctx.restoreGState()

    // Metallic ring
    let ringInset = radius * 0.06
    let ringRect = CGRect(x: center.x - radius + ringInset, y: center.y - radius + ringInset,
                          width: (radius - ringInset) * 2, height: (radius - ringInset) * 2)
    ctx.saveGState()
    ctx.addEllipse(in: ringRect)
    ctx.clip()
    let ringGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [rgb(120, 126, 136), rgb(48, 52, 58)] as CFArray,
                                  locations: [0, 1])!
    ctx.drawLinearGradient(ringGradient,
                           start: CGPoint(x: center.x, y: ringRect.maxY),
                           end: CGPoint(x: center.x, y: ringRect.minY),
                           options: [])
    ctx.restoreGState()

    // Cap
    let capRadius = radius * 0.82
    let capRect = CGRect(x: center.x - capRadius, y: center.y - capRadius,
                         width: capRadius * 2, height: capRadius * 2)
    ctx.saveGState()
    ctx.addEllipse(in: capRect)
    ctx.clip()
    let hot = lit ? (rgb(255, 92, 78), rgb(176, 26, 18)) : (rgb(196, 60, 50), rgb(122, 18, 12))
    let capGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [hot.0, hot.1] as CFArray,
                                 locations: [0, 1])!
    ctx.drawRadialGradient(capGradient,
                           startCenter: CGPoint(x: center.x - capRadius * 0.3, y: center.y + capRadius * 0.35),
                           startRadius: 0,
                           endCenter: center,
                           endRadius: capRadius * 1.25,
                           options: [])
    // Specular highlight across the upper third.
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgb(255, 255, 255, 0.42), rgb(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: center.x, y: capRect.maxY),
                           end: CGPoint(x: center.x, y: center.y + capRadius * 0.05),
                           options: [])
    ctx.restoreGState()
}

/// Custom microphone silhouette — deliberately not an SF Symbol, since Apple
/// asks that those stay out of app icons.
func micPath(center: CGPoint, height: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func y(_ fraction: CGFloat) -> CGFloat { center.y + height * fraction }
    let stroke = height * 0.075

    // Capsule: the mic body, sitting in the upper half.
    let capsuleWidth = height * 0.34
    let capsuleTop = y(0.46)
    let capsuleBottom = y(-0.02)
    path.addRoundedRect(in: CGRect(x: center.x - capsuleWidth / 2,
                                   y: capsuleBottom,
                                   width: capsuleWidth,
                                   height: capsuleTop - capsuleBottom),
                        cornerWidth: capsuleWidth / 2,
                        cornerHeight: capsuleWidth / 2)

    // Cradle: the LOWER semicircle, wrapping under the capsule. Sweeping π→2π
    // counterclockwise passes through 3π/2 (the bottom); the clockwise sweep
    // π→0 would trace the top and collide with the capsule instead.
    let arcRadius = height * 0.30
    let arcCenter = CGPoint(x: center.x, y: capsuleBottom)
    let arc = CGMutablePath()
    arc.addArc(center: arcCenter, radius: arcRadius,
               startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    path.addPath(arc.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))

    // Stem: from the bottom of the cradle down to the foot.
    let stemTop = arcCenter.y - arcRadius
    let stemBottom = y(-0.42)
    path.addRoundedRect(in: CGRect(x: center.x - stroke / 2,
                                   y: stemBottom,
                                   width: stroke,
                                   height: stemTop - stemBottom),
                        cornerWidth: stroke / 2, cornerHeight: stroke / 2)

    // Foot
    let footWidth = height * 0.30
    path.addRoundedRect(in: CGRect(x: center.x - footWidth / 2,
                                   y: stemBottom - stroke,
                                   width: footWidth,
                                   height: stroke),
                        cornerWidth: stroke / 2, cornerHeight: stroke / 2)
    return path
}

// MARK: - Concepts

/// A — the literal broadcast cough button.
func conceptButton() -> NSImage {
    makeImage { ctx in
        drawPlate(ctx, top: rgb(58, 64, 74), bottom: rgb(22, 25, 30))
        drawPushButton(ctx,
                       center: CGPoint(x: size / 2, y: size / 2),
                       radius: artSize * 0.30,
                       lit: true)
    }
}

/// B — microphone with a mute slash. Function over metaphor.
func conceptMic() -> NSImage {
    makeImage { ctx in
        drawPlate(ctx, top: rgb(70, 76, 88), bottom: rgb(26, 29, 35))
        let center = CGPoint(x: size / 2, y: size / 2 + artSize * 0.01)
        let mic = micPath(center: center, height: artSize * 0.60)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.018, color: rgb(0, 0, 0, 0.45))
        ctx.addPath(mic)
        ctx.setFillColor(rgb(244, 246, 250))
        ctx.fillPath()
        ctx.restoreGState()

        // Slash: a dark cut, then the red bar sitting inside it.
        let inset = artSize * 0.16
        let start = CGPoint(x: artRect().minX + inset, y: artRect().minY + inset)
        let end = CGPoint(x: artRect().maxX - inset, y: artRect().maxY - inset)
        let bar = CGMutablePath()
        bar.move(to: start)
        bar.addLine(to: end)

        ctx.saveGState()
        ctx.addPath(bar.copy(strokingWithWidth: artSize * 0.155, lineCap: .round, lineJoin: .round, miterLimit: 10))
        ctx.setFillColor(rgb(26, 29, 35))
        ctx.fillPath()
        ctx.addPath(bar.copy(strokingWithWidth: artSize * 0.085, lineCap: .round, lineJoin: .round, miterLimit: 10))
        ctx.setFillColor(rgb(236, 62, 50))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// C — the mic embossed on the push button. Name and function in one mark.
func conceptMicButton() -> NSImage {
    makeImage { ctx in
        drawPlate(ctx, top: rgb(58, 64, 74), bottom: rgb(22, 25, 30))
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = artSize * 0.31
        drawPushButton(ctx, center: center, radius: radius, lit: true)

        let mic = micPath(center: center, height: radius * 1.05)
        ctx.saveGState()
        // Slight dark offset underneath reads as engraving rather than a sticker.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -size * 0.004)
        ctx.addPath(mic)
        ctx.setFillColor(rgb(90, 10, 6, 0.55))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(mic)
        ctx.setFillColor(rgb(255, 244, 242, 0.96))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// D — a waveform interrupted mid-flow. Abstract, quiet, no metaphor debt.
func conceptWave() -> NSImage {
    makeImage { ctx in
        drawPlate(ctx, top: rgb(46, 52, 64), bottom: rgb(18, 21, 27))
        let rect = artRect()
        let bars: [CGFloat] = [0.22, 0.42, 0.66, 0.92, 0.55, 0, 0, 0.55, 0.92, 0.66, 0.42, 0.22]
        let barWidth = rect.width * 0.052
        let gap = (rect.width * 0.70 - barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        let totalWidth = barWidth * CGFloat(bars.count) + gap * CGFloat(bars.count - 1)
        var x = rect.midX - totalWidth / 2

        for height in bars {
            defer { x += barWidth + gap }
            guard height > 0 else { continue }
            let h = rect.height * 0.62 * height
            let barRect = CGRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
            ctx.addPath(roundedPath(barRect, barWidth / 2))
            ctx.setFillColor(rgb(226, 232, 242))
            ctx.fillPath()
        }

        // The break: a red dot where the sound stops.
        let dotRadius = barWidth * 0.72
        ctx.setFillColor(rgb(236, 62, 50))
        ctx.fillEllipse(in: CGRect(x: rect.midX - dotRadius, y: rect.midY - dotRadius,
                                   width: dotRadius * 2, height: dotRadius * 2))
    }
}

// MARK: - Output

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(url.lastPathComponent)\n".data(using: .utf8)!)
        return
    }
    try? png.write(to: url)
    print("wrote \(url.path)")
}

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let which = args.count > 2 ? args[2] : "all"

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let concepts: [(String, () -> NSImage)] = [
    ("a-button", conceptButton),
    ("b-mic", conceptMic),
    ("c-micbutton", conceptMicButton),
    ("d-wave", conceptWave)
]

if which == "app" {
    // The shipping icon: concept C, the mic embossed on the push button.
    // build-app.sh turns this into AppIcon.icns at bundle time.
    writePNG(conceptMicButton(), to: outDir.appendingPathComponent("AppIcon.png"))
} else {
    for (name, make) in concepts where which == "all" || name.contains(which) {
        writePNG(make(), to: outDir.appendingPathComponent("icon-\(name).png"))
    }
}
