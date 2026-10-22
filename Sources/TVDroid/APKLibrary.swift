import AppKit
import Foundation

/// One APK file in the library folder.
struct APKItem: Identifiable, Hashable {
    let url: URL
    let modified: Date
    var label: String
    var packageName: String?
    var versionCode: Int?
    var versionName: String?
    /// Activity to start. TV (leanback) activity has priority over phone activity.
    var launchActivity: String?
    var isTVApp: Bool = false
    var icon: NSImage?
    var banner: NSImage?

    var id: URL { url }
}

/// Watches the APK folder and reads the metadata of each APK.
@MainActor
final class APKLibrary: ObservableObject {
    static let folder: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("TVDroid/APKs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Published private(set) var items: [APKItem] = []

    private var cache: [URL: APKItem] = [:]
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        startWatching()
        Task { await reload() }
    }

    func reload() async {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(
            at: Self.folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension.lowercased() == "apk" }

        var result: [APKItem] = []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let cached = cache[url], cached.modified == modified {
                result.append(cached)
                continue
            }
            let item = await Self.inspect(url: url, modified: modified)
            cache[url] = item
            result.append(item)
        }
        items = result.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func revealFolder() {
        NSWorkspace.shared.open(Self.folder)
    }

    // MARK: - Folder watcher

    private func startWatching() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Wait a moment so that large files can finish copying.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                await self?.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: - APK metadata

    private static func inspect(url: URL, modified: Date) async -> APKItem {
        var item = APKItem(url: url, modified: modified, label: url.deletingPathExtension().lastPathComponent)
        guard let aapt2 = Tools.aapt2 else { return item }
        let result = await Shell.run(aapt2, ["dump", "badging", url.path])
        guard result.ok || result.output.contains("package:") else { return item }

        var iconPaths: [(Int, String)] = []
        var bannerPath: String?
        var phoneActivity: String?
        var tvActivity: String?

        for line in result.output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("package:") {
                item.packageName = value(of: "name", in: line)
                item.versionCode = value(of: "versionCode", in: line).flatMap { Int($0) }
                item.versionName = value(of: "versionName", in: line)
            } else if line.hasPrefix("application-label:") {
                item.label = quoted(line) ?? item.label
            } else if line.hasPrefix("application-icon-") {
                let density = Int(line.dropFirst("application-icon-".count).prefix { $0.isNumber }) ?? 0
                if let path = quoted(line) { iconPaths.append((density, path)) }
            } else if line.hasPrefix("leanback-launchable-activity:") {
                tvActivity = value(of: "name", in: line)
                bannerPath = value(of: "banner", in: line).flatMap { $0.isEmpty ? nil : $0 }
            } else if line.hasPrefix("launchable-activity:") {
                phoneActivity = value(of: "name", in: line)
            }
        }

        item.isTVApp = tvActivity != nil
        item.launchActivity = tvActivity ?? phoneActivity

        // Use the largest bitmap icon. Adaptive icons (.xml) cannot be shown, so skip them.
        let bitmaps = iconPaths
            .filter { ["png", "webp", "jpg"].contains(($0.1 as NSString).pathExtension.lowercased()) }
            .sorted { $0.0 > $1.0 }
        for (_, path) in bitmaps {
            if let image = await extractImage(apk: url, path: path) { item.icon = image; break }
        }
        if item.icon == nil {
            item.icon = await findLauncherBitmap(apk: url)
        }
        if let bannerPath, ["png", "webp", "jpg"].contains((bannerPath as NSString).pathExtension.lowercased()) {
            item.banner = await extractImage(apk: url, path: bannerPath)
        }
        return item
    }

    /// Fallback when the manifest icon is adaptive: look for a launcher bitmap inside the APK.
    private static func findLauncherBitmap(apk: URL) async -> NSImage? {
        let list = await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", apk.path])
        let order = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"]
        let candidates = list.output.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("res/mipmap") && $0.contains("ic_launcher") && !$0.contains("foreground")
                && !$0.contains("background") && ($0.hasSuffix(".png") || $0.hasSuffix(".webp"))
        }
        let sorted = candidates.sorted { a, b in
            (order.firstIndex { a.contains($0) } ?? 99) < (order.firstIndex { b.contains($0) } ?? 99)
        }
        guard let best = sorted.first else { return nil }
        return await extractImage(apk: apk, path: best)
    }

    private static func extractImage(apk: URL, path: String) async -> NSImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-p", apk.path, path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: data.isEmpty ? nil : NSImage(data: data))
            }
        }
    }

    private static func value(of key: String, in line: String) -> String? {
        guard let range = line.range(of: " \(key)='") ?? line.range(of: "\(key)='") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    private static func quoted(_ line: String) -> String? {
        guard let start = line.firstIndex(of: "'") else { return nil }
        let rest = line[line.index(after: start)...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }
}
