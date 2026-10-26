import AppKit
import Foundation

/// Looks for a newer TVDroid release on GitHub. At launch at most once a day, or from the menu.
@MainActor
enum UpdateChecker {
    private static let latestURL = URL(string: "https://api.github.com/repos/dilip1232/TVDroid/releases/latest")!
    private static let lastCheckKey = "updateLastCheck"
    private static let skippedKey = "updateSkippedVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Quiet check at launch: shows a message only if there is a new version.
    static func checkAtLaunch() {
        // A debug build from `swift run` has no version. Do not check.
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    static func check(userInitiated: Bool) async {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard isNewer(latest, than: currentVersion) else {
                if userInitiated { inform("TVDroid is up to date", "Version \(currentVersion) is the newest version.") }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: skippedKey) == latest { return }
            offer(latest, release: release)
        } catch {
            if userInitiated { inform("Cannot check for updates", error.localizedDescription) }
        }
    }

    /// Compares versions like 1.10.0 and 1.9.2 number by number.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func offer(_ version: String, release: Release) {
        let alert = NSAlert()
        alert.messageText = "TVDroid \(version) is available"
        alert.informativeText = "You have version \(currentVersion). Download the new DMG and drag TVDroid to Applications. Your apps and TV data stay."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadURL
            NSWorkspace.shared.open(dmg ?? release.htmlURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: skippedKey)
        default:
            break
        }
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, browserDownloadURL = "browser_download_url"
        }
    }
}
