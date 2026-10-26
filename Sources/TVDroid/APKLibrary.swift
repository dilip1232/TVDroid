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
    /// The APK files to install. One file for a plain .apk. Base and split APKs for .xapk, .apks and .apkm.
    var installFiles: [URL] = []
    /// OBB data files of an .xapk: the local file and the path below /sdcard on the TV.
    var obbFiles: [(local: URL, remote: String)] = []

    var id: URL { url }
    var isBundle: Bool { APKLibrary.bundleExtensions.contains(url.pathExtension.lowercased()) }

    static func == (a: APKItem, b: APKItem) -> Bool { a.url == b.url && a.modified == b.modified }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Watches the APK folder and reads the metadata of each APK.
@MainActor
final class APKLibrary: ObservableObject {
    static let folder: URL = {
        let url = Tools.home.appendingPathComponent("TVDroid/APKs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// File types in the library. .xapk (APKPure), .apks (bundletool, SAI) and .apkm (APKMirror)
    /// are zip files with a base APK, split APKs and, for .xapk, OBB data.
    nonisolated static let bundleExtensions: Set<String> = ["xapk", "apks", "apkm"]
    nonisolated static let extensions: Set<String> = bundleExtensions.union(["apk"])

    /// Bundles are unpacked here once. The folder name changes when the file changes.
    nonisolated static var bundleCache: URL {
        Tools.home.appendingPathComponent("TVDroid/.cache/bundles", isDirectory: true)
    }

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
        )) ?? []).filter { Self.extensions.contains($0.pathExtension.lowercased()) }

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
        removeOldBundleFolders(keeping: result)
    }

    /// Copies dropped files into the APK folder. Returns the number of files that were added.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        let fm = FileManager.default
        for url in urls where Self.extensions.contains(url.pathExtension.lowercased()) {
            let target = Self.folder.appendingPathComponent(url.lastPathComponent)
            guard url.standardizedFileURL != target.standardizedFileURL else { continue }
            try? fm.removeItem(at: target)
            if (try? fm.copyItem(at: url, to: target)) != nil { added += 1 }
        }
        Task { await reload() }
        return added
    }

    /// Moves the file to the Trash. The app stays on the TV.
    func trash(_ item: APKItem) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in
            Task { @MainActor in await self.reload() }
        }
    }

    private func removeOldBundleFolders(keeping items: [APKItem]) {
        let keep = Set(items.filter(\.isBundle).map { Self.bundleFolder(for: $0.url, modified: $0.modified).lastPathComponent })
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Self.bundleCache.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: Self.bundleCache.appendingPathComponent(name))
        }
    }

    /// Reads all APKs again, for example after the setup installed aapt2.
    func rescan() async {
        cache.removeAll()
        await reload()
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
        var apk = url
        if item.isBundle {
            guard let bundle = await unpack(url, modified: modified) else { return item }
            apk = bundle.base
            item.installFiles = bundle.apks
            item.obbFiles = bundle.obbs
        } else {
            item.installFiles = [url]
        }
        guard let aapt2 = Tools.aapt2 else { return item }
        let result = await Shell.run(aapt2, ["dump", "badging", apk.path])
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
            if let image = await extractImage(apk: apk, path: path) { item.icon = image; break }
        }
        if item.icon == nil {
            item.icon = await findLauncherBitmap(apk: apk)
        }
        if let bannerPath, ["png", "webp", "jpg"].contains((bannerPath as NSString).pathExtension.lowercased()) {
            item.banner = await extractImage(apk: apk, path: bannerPath)
        }
        if item.isBundle, item.icon == nil, let icon = await bundleIcon(url) { item.icon = icon }
        return item
    }

    // MARK: - Bundles (.xapk, .apks, .apkm)

    struct Bundle {
        let base: URL
        let apks: [URL]
        let obbs: [(local: URL, remote: String)]
    }

    nonisolated static func bundleFolder(for url: URL, modified: Date) -> URL {
        let key = "\(url.deletingPathExtension().lastPathComponent)-\(Int(modified.timeIntervalSince1970))"
            .replacingOccurrences(of: "/", with: "_")
        return bundleCache.appendingPathComponent(key, isDirectory: true)
    }

    /// Unpacks the bundle (once) and finds the base APK, the split APKs for this TV, and OBB files.
    private static func unpack(_ url: URL, modified: Date) async -> Bundle? {
        let fm = FileManager.default
        let folder = bundleFolder(for: url, modified: modified)
        let done = folder.appendingPathComponent(".unpacked")
        if !fm.fileExists(atPath: done.path) {
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-o", "-qq", url.path, "-d", folder.path])
            guard result.ok else {
                NSLog("TVDroid: cannot unpack \(url.lastPathComponent): \(result.output)")
                return nil
            }
            fm.createFile(atPath: done.path, contents: nil)
        }

        let files = (fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
        var apks = files.filter { $0.pathExtension.lowercased() == "apk" }
        guard !apks.isEmpty else { return nil }

        // Native code splits for other CPUs do not install on an ARM64 TV.
        let names = apks.map { $0.lastPathComponent.lowercased() }
        let hasArm64 = names.contains { $0.contains("arm64") }
        apks.removeAll { url in
            let name = url.lastPathComponent.lowercased()
            if name.contains("x86") { return true }
            if hasArm64, name.contains("armeabi") { return true }
            return false
        }

        let base = findBase(apks, manifest: folder.appendingPathComponent("manifest.json"))
        // The base APK must come first for `adb install-multiple`.
        let ordered = [base] + apks.filter { $0 != base }

        var obbs: [(URL, String)] = []
        for file in files where file.pathExtension.lowercased() == "obb" {
            let path = file.path
            if let range = path.range(of: "/Android/obb/") {
                obbs.append((file, "Android/obb/" + path[range.upperBound...]))
            }
        }
        return Bundle(base: base, apks: ordered, obbs: obbs)
    }

    /// The base APK: from manifest.json (.xapk), else "base.apk" / "base-master.apk", else the largest APK.
    private static func findBase(_ apks: [URL], manifest: URL) -> URL {
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let splits = json["split_apks"] as? [[String: Any]],
               let file = splits.first(where: { ($0["id"] as? String) == "base" })?["file"] as? String,
               let match = apks.first(where: { $0.lastPathComponent == file }) {
                return match
            }
            if let package = json["package_name"] as? String,
               let match = apks.first(where: { $0.lastPathComponent == package + ".apk" }) {
                return match
            }
        }
        for name in ["base.apk", "base-master.apk"] {
            if let match = apks.first(where: { $0.lastPathComponent.lowercased() == name }) { return match }
        }
        if let match = apks.first(where: { !$0.lastPathComponent.lowercased().contains("config.") && !$0.lastPathComponent.lowercased().hasPrefix("split_") }) {
            return match
        }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return apks.max { size($0) < size($1) }!
    }

    /// .xapk files have an icon.png next to the APKs.
    private static func bundleIcon(_ url: URL) async -> NSImage? {
        await extractImage(apk: url, path: "icon.png")
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
