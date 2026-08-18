import Foundation

// ---------------------------------------------------------------------------
// DiagLog — a size-capped record of actions that could not be verified.
//
// Only failures are written. In normal use this file stays empty, so anything
// in it is a real event worth looking at: "the hotkey sometimes doesn't
// register" becomes a timestamped line naming which control, how many presses
// were spent, and what the window situation was at the time.
//
// **Deliberately records no window titles, meeting names, participants or
// account identifiers** — only mechanical facts. The log is meant to be safe to
// paste into a public issue.
// ---------------------------------------------------------------------------

public enum DiagLog {

    private static let queue = DispatchQueue(label: "com.victorrodrigues.coughbutton.diaglog")
    private static let maxBytes = 256 * 1024

    /// `COUGHBUTTON_LOG_DIR` lets the test suite redirect writes away from the
    /// real log. Tests run with Accessibility genuinely granted (it is a real
    /// system gate, not mocked), so without this override, exercising the
    /// normal miss/recovery paths would write real-looking diagnostic lines
    /// into the user's actual log on every `swift test` run.
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["COUGHBUTTON_LOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoughButton", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("coughbutton.log") }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func write(_ line: String) {
        queue.async {
            let entry = "\(stamp.string(from: Date()))  \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL)
                return
            }
            // Rotate rather than grow without bound; one previous generation is
            // plenty for a log that only records failures.
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
                let old = fileURL.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
                try? data.write(to: fileURL)
                return
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
