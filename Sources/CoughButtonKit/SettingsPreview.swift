import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// SettingsPreview — renders the settings window to a PNG.
//
//   CoughButton --render-settings <dir> [height]
//
// Same reasoning as StatusIconDump: sizing a window by launching it, squinting,
// and dragging the corner is slow and imprecise. This renders the real view at
// a given size so clipping is obvious, and so the chosen height is arrived at
// by looking rather than by guessing.
// ---------------------------------------------------------------------------

public enum SettingsPreview {

    @MainActor
    public static func run(outputDir: String, height: CGFloat) {
        // A scratch defaults domain, so previewing never disturbs real settings.
        let suite = UserDefaults(suiteName: "com.victorrodrigues.coughbutton.preview")!
        suite.removePersistentDomain(forName: "com.victorrodrigues.coughbutton.preview")
        let model = SettingsViewModel(store: SettingsStore(defaults: suite),
                                      onRecordingChange: { _ in },
                                      onChange: {})

        let hosting = NSHostingView(rootView: SettingsView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: height)
        hosting.layoutSubtreeIfNeeded()

        // Give SwiftUI a run-loop turn to settle its layout before capture.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("could not create bitmap"); return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("settings-\(Int(height)).png")
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("wrote \(url.path)  (content fits in \(Int(hosting.fittingSize.height))pt)")
        }
    }
}
