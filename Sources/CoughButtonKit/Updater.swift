import Foundation
import AppKit

// ---------------------------------------------------------------------------
// Updater — silent auto-update against GitHub Releases.
//
// Ported from BarPilot, where this replaced Sparkle: a hand-assembled SwiftPM
// bundle makes Sparkle's embedded framework + XPC services more trouble than
// they are worth, and this needs no appcast, no signing keys and no dependency.
//
// Checks the Releases API, downloads the notarised DMG, verifies it is signed
// by our Developer ID team AND accepted by Gatekeeper before trusting it, then
// swaps the bundle via a detached helper and relaunches.
//
// Gated to Developer ID builds, so local dev builds never self-update.
// ---------------------------------------------------------------------------

public final class Updater {
    private static let repo = "vmlrodrigues/CoughButton"
    private static let teamID = "9N354A3UZK"
    private static let appName = "CoughButton"
    private let interval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    public init() {}

    // MARK: Lifecycle

    @MainActor
    public func start() {
        guard !Self.isDevBuild else {
            NSLog("CoughButton: auto-update disabled (not a Developer ID build)")
            return
        }
        Self.checkNow(afterSeconds: 20)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Updater.checkNow()
        }
    }

    public static func checkNow(afterSeconds delay: TimeInterval = 0) {
        Task.detached(priority: .background) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await performCheck()
        }
    }

    /// Menu-driven check. Unlike the background path this reports back, because
    /// a "Check for Updates…" that appears to do nothing is worse than none.
    @MainActor
    public static func checkNowUserInitiated() {
        Task.detached(priority: .userInitiated) {
            let latest = await latestRelease()
            guard let latest else {
                await MainActor.run { alert("Couldn't check for updates",
                                            "Unable to reach GitHub. Please try again later.") }
                return
            }
            guard isNewer(latest.version, than: currentVersion()) else {
                await MainActor.run { alert("You're up to date",
                                            "\(appName) \(currentVersion()) is the latest version.") }
                return
            }
            await MainActor.run { alert("Update available",
                                        "\(appName) \(latest.version) is downloading and will install shortly.") }
            await performCheck()
        }
    }

    @MainActor
    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: Check → download → verify → install

    private static func performCheck() async {
        guard let latest = await latestRelease(),
              isNewer(latest.version, than: currentVersion()) else { return }
        NSLog("CoughButton: update available \(currentVersion()) -> \(latest.version)")

        guard let dmg = await download(latest.dmgURL) else { return }
        defer { try? FileManager.default.removeItem(at: dmg) }

        guard let staged = mountExtractAndVerify(dmg: dmg) else { return }
        await MainActor.run { installAndRelaunch(staged: staged) }
    }

    // MARK: GitHub API

    private struct Release { let version: String; let dmgURL: URL }

    private static func latestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(appName, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let urlStr = asset["browser_download_url"] as? String,
              let dmgURL = URL(string: urlStr) else { return nil }

        return Release(version: version, dmgURL: dmgURL)
    }

    private static func download(_ url: URL) async -> URL? {
        guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(appName)-update-\(UUID().uuidString).dmg")
        do { try FileManager.default.moveItem(at: tmp, to: dest); return dest } catch { return nil }
    }

    // MARK: Mount + verify

    private static func mountExtractAndVerify(dmg: URL) -> URL? {
        guard let mount = hdiutilAttach(dmg) else { return nil }
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let appInDMG = URL(fileURLWithPath: mount).appendingPathComponent("\(appName).app")
        guard FileManager.default.fileExists(atPath: appInDMG.path) else { return nil }

        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(appName)-stage-\(UUID().uuidString)")
        let staged = stageDir.appendingPathComponent("\(appName).app")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        guard runTool("/usr/bin/ditto", [appInDMG.path, staged.path]).status == 0 else {
            try? FileManager.default.removeItem(at: stageDir); return nil
        }
        guard verify(app: staged) else {
            NSLog("CoughButton: update rejected — signature/team/Gatekeeper check failed")
            try? FileManager.default.removeItem(at: stageDir); return nil
        }
        return staged
    }

    private static func verify(app: URL) -> Bool {
        guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            NSLog("CoughButton: update verify failed — codesign --verify")
            return false
        }
        let info = runTool("/usr/bin/codesign", ["-dvv", app.path]).output
        guard info.contains("TeamIdentifier=\(teamID)") else {
            NSLog("CoughButton: update verify failed — TeamIdentifier mismatch")
            return false
        }
        guard runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else {
            NSLog("CoughButton: update verify failed — Gatekeeper assessment")
            return false
        }
        return true
    }

    private static func hdiutilAttach(_ dmg: URL) -> String? {
        let r = runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard r.status == 0, let data = r.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    // MARK: Install + relaunch

    @MainActor
    private static func installAndRelaunch(staged: URL) {
        let dest = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/sh
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /usr/bin/ditto "\(staged.path)" "\(dest.path).new" || exit 1
        /bin/rm -rf "\(dest.path)"
        /bin/mv "\(dest.path).new" "\(dest.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        /bin/rm -rf "\(staged.deletingLastPathComponent().path)"
        /usr/bin/open "\(dest.path)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("coughbutton-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()); return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "nohup \"\(scriptURL.path)\" >/dev/null 2>&1 &"]
        do { try task.run(); task.waitUntilExit() } catch {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()); return
        }
        NSLog("CoughButton: installing update and relaunching")
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    @discardableResult
    private static func runTool(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// True if `a` is a strictly higher dotted version than `b`.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    public static func isDeveloperIDSigned() -> Bool {
        let out = runTool("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath]).output
        return out.contains("TeamIdentifier=\(teamID)") && out.contains("Authority=Developer ID Application")
    }

    /// Stamped into the bundle by `build-app.sh` for anything that is not
    /// `make release`.
    ///
    /// This can't be inferred from the signature any more: local builds are
    /// signed with the same Developer ID certificate as releases, deliberately,
    /// so that macOS keeps their Accessibility grant across rebuilds instead of
    /// binding it to a throwaway ad-hoc cdhash.
    public static func hasDevBuildMarker() -> Bool {
        Bundle.main.infoDictionary?["CBDevBuild"] as? Bool == true
    }

    public static let isDevBuild: Bool = hasDevBuildMarker() || !isDeveloperIDSigned()
}
