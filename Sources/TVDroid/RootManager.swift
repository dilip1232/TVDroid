import AppKit
import CryptoKit
import Foundation

/// Rooted TV (experimental). The Google TV image is a "user" build without `adb root`.
/// TVDroid patches a copy of the system image's ramdisk with Magisk (with rootAVD by NewBit) and
/// starts the TV with `-ramdisk <copy>`. The SDK files stay unchanged, so turning root off only
/// starts the TV with the original ramdisk again. Google TV, Play Store and all apps stay.
@MainActor
final class RootManager: ObservableObject {
    static let shared = RootManager()

    /// rootAVD version (GitLab commit). A fixed version, so a change upstream cannot break TVDroid.
    nonisolated static let rootAVDCommit = "613caa44371f85e1a461bc030e07ddc2d71afe32"
    nonisolated static let magiskPackage = "com.topjohnwu.magisk"
    nonisolated static let hostsURL = URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!

    @Published private(set) var isOn = Prefs.rootedTV
    /// True after TVDroid got a root shell on the running TV.
    @Published private(set) var isWorking = false
    @Published private(set) var adBlocking = false
    @Published private(set) var busyMessage: String?
    @Published var errorMessage: String?

    private init() {}

    // MARK: - Files

    nonisolated static var folder: URL {
        let url = Tools.home.appendingPathComponent("TVDroid/root", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    nonisolated static var patchedRamdisk: URL { folder.appendingPathComponent("ramdisk-magisk.img") }
    nonisolated static var stockHashFile: URL { folder.appendingPathComponent("ramdisk-stock.sha256") }
    nonisolated static var magiskAPK: URL { folder.appendingPathComponent("Magisk.apk") }
    nonisolated static var logFile: URL { Tools.home.appendingPathComponent("TVDroid/logs/root.log") }
    nonisolated static var backupsFolder: URL { Tools.home.appendingPathComponent("TVDroid/Backups", isDirectory: true) }

    /// Path of the system image relative to the SDK, for example "system-images/android-34/google-tv/arm64-v8a".
    nonisolated static var imagePath: String { SetupManager.systemImage.replacingOccurrences(of: ";", with: "/") }
    nonisolated static var stockRamdisk: URL { Tools.sdkRoot.appendingPathComponent(imagePath + "/ramdisk.img") }

    nonisolated(unsafe) private static var hashCache: (key: String, hash: String)?
    nonisolated private static let hashLock = NSLock()

    /// SHA-256 of a file. The result is kept while the file's size and date stay the same.
    nonisolated private static func sha256(_ url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\((attributes?[.size] as? Int) ?? -1)|\(((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
        hashLock.lock()
        if let cached = hashCache, cached.key == key { hashLock.unlock(); return cached.hash }
        hashLock.unlock()
        guard let hash = uncachedSHA256(url) else { return nil }
        hashLock.lock(); hashCache = (key, hash); hashLock.unlock()
        return hash
    }

    nonisolated private static func uncachedSHA256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when the patched ramdisk was made from the system image that is installed now.
    /// After an update of the system image, the old patched ramdisk does not fit and is not used.
    nonisolated static var patchFitsImage: Bool {
        guard FileManager.default.fileExists(atPath: patchedRamdisk.path),
              let saved = try? String(contentsOf: stockHashFile, encoding: .utf8) else { return false }
        return saved.trimmingCharacters(in: .whitespacesAndNewlines) == sha256(stockRamdisk)
    }

    /// Root is on, but the patch does not fit the installed system image (for example after an update).
    var needsNewPatch: Bool { isOn && !Self.patchFitsImage }

    /// Extra emulator arguments. Empty when root is off.
    nonisolated static var emulatorArguments: [String] {
        guard Prefs.rootedTV, patchFitsImage else { return [] }
        return ["-ramdisk", patchedRamdisk.path]
    }

    // MARK: - Root on/off

    func setRoot(_ on: Bool, tv: TVController) async {
        guard busyMessage == nil, tv.busyMessage == nil, tv.busyItem == nil else { return }
        defer { busyMessage = nil }
        errorMessage = nil
        if !on {
            Prefs.rootedTV = false
            isOn = false
            isWorking = false
            adBlocking = false
            if tv.state != .off {
                busyMessage = "Restarting the TV without root…"
                await tv.restart()
            }
            return
        }
        do {
            if !Self.patchFitsImage {
                try await makePatchedRamdisk(tv: tv)
            }
            Prefs.rootedTV = true
            isOn = true
            busyMessage = "Starting the rooted TV…"
            if tv.state != .off { await tv.stop() }
            try await tv.boot()
            TVWindowController.shared.show(fullScreen: false)
            try await prepare()
        } catch {
            errorMessage = error.localizedDescription
            log("ERROR: \(error.localizedDescription)")
        }
    }

    /// Patches a copy of the ramdisk. rootAVD runs Magisk's tools inside the running TV.
    private func makePatchedRamdisk(tv: TVController) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.stockRamdisk.path) else {
            throw ShellError.failed("The TV system image is missing (\(Self.stockRamdisk.path)). Finish the setup first.")
        }
        // A stopped earlier run can leave the patched file in the SDK. Put the original back first.
        Self.restoreStockRamdisk()
        let stockHash = Self.sha256(Self.stockRamdisk)

        busyMessage = "Starting the TV…"
        try await tv.boot()

        busyMessage = "Downloading rootAVD…"
        let tool = try await downloadRootAVD()
        try writeBootScripts(into: tool)

        busyMessage = "Patching with Magisk…"
        try? fm.removeItem(at: Self.logFile)
        let lines = LineCollector()
        Self.isPatching = true
        let status = await Shell.stream(
            URL(fileURLWithPath: "/bin/bash"),
            ["-c", "cd \(Shell.quote(tool.path)) && ./rootAVD.sh \(Shell.quote(Self.imagePath + "/ramdisk.img")) AddRCscripts"],
            input: "",
            extraEnvironment: ["ANDROID_SERIAL": TVController.serial, "ANDROID_HOME": Tools.sdkRoot.path]
        ) { line in
            lines.append(line)
            RootManager.appendLog(line)
        }
        Self.isPatching = false
        defer { Self.restoreStockRamdisk() }

        let backup = URL(fileURLWithPath: Self.stockRamdisk.path + ".backup")
        guard status == 0, fm.fileExists(atPath: backup.path), Self.sha256(Self.stockRamdisk) != stockHash else {
            let reason = lines.last { $0.hasPrefix("[!]") || $0.lowercased().contains("error") } ?? "rootAVD stopped."
            throw ShellError.failed("TVDroid could not patch the TV with Magisk: \(reason) See ~/TVDroid/logs/root.log.")
        }
        try? fm.removeItem(at: Self.patchedRamdisk)
        try fm.copyItem(at: Self.stockRamdisk, to: Self.patchedRamdisk)
        try (stockHash ?? "").write(to: Self.stockHashFile, atomically: true, encoding: .utf8)
        let apk = tool.appendingPathComponent("Apps/Magisk.apk")
        if fm.fileExists(atPath: apk.path) {
            try? fm.removeItem(at: Self.magiskAPK)
            try? fm.copyItem(at: apk, to: Self.magiskAPK)
        }

        // rootAVD shuts the TV down at the end. Wait for it, so the next start is clean.
        busyMessage = "Waiting for the TV to shut down…"
        for _ in 0..<60 where tv.isEmulatorRunning {
            try? await Task.sleep(for: .milliseconds(500))
        }
        await tv.stop()
    }

    /// True while rootAVD runs. Then the SDK holds the patched ramdisk on purpose.
    nonisolated(unsafe) private static var isPatching = false

    /// rootAVD leaves the original as ramdisk.img.backup. TVDroid keeps the SDK unchanged.
    /// Also called at launch and before each start, in case TVDroid stopped during a patch.
    nonisolated static func restoreStockRamdisk() {
        guard !isPatching else { return }
        let fm = FileManager.default
        let backup = URL(fileURLWithPath: stockRamdisk.path + ".backup")
        guard fm.fileExists(atPath: backup.path) else { return }
        if fm.fileExists(atPath: stockRamdisk.path) {
            _ = try? fm.replaceItemAt(stockRamdisk, withItemAt: backup)
        } else {
            try? fm.moveItem(at: backup, to: stockRamdisk)
        }
    }

    private func downloadRootAVD() async throws -> URL {
        let fm = FileManager.default
        let name = "rootAVD-\(Self.rootAVDCommit)"
        let tool = Self.folder.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: tool.appendingPathComponent("rootAVD.sh").path) { return tool }
        let url = URL(string: "https://gitlab.com/newbit/rootAVD/-/archive/\(Self.rootAVDCommit)/\(name).zip")!
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShellError.failed("TVDroid could not download rootAVD from GitLab. Check the internet connection.")
        }
        let zip = Self.folder.appendingPathComponent("rootAVD.zip")
        try? fm.removeItem(at: zip)
        try fm.moveItem(at: file, to: zip)
        defer { try? fm.removeItem(at: zip) }
        // Unpack into a new folder and rename it at the end, so a stopped unpack is never used.
        let temp = Self.folder.appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let unzip = await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, temp.path])
        let unpacked = temp.appendingPathComponent(name, isDirectory: true)
        guard unzip.ok, fm.fileExists(atPath: unpacked.appendingPathComponent("rootAVD.sh").path) else {
            throw ShellError.failed("TVDroid could not unpack rootAVD: \(unzip.output)")
        }
        try? fm.removeItem(at: tool)
        try fm.moveItem(at: unpacked, to: tool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.appendingPathComponent("rootAVD.sh").path)
        return tool
    }

    /// rootAVD adds *.rc files and sbin/* to the ramdisk (option AddRCscripts). Magisk runs them as root.
    /// The script lets adb shell (uid 2000) use `su` without a prompt on the TV, like `adb root` on a
    /// debug build. Then it sets the property tvdroid.root, so TVDroid knows when root is ready.
    private func writeBootScripts(into tool: URL) throws {
        let sbin = tool.appendingPathComponent("sbin", isDirectory: true)
        try FileManager.default.createDirectory(at: sbin, withIntermediateDirectories: true)
        try """
        on property:sys.boot_completed=1
            exec_background u:r:magisk:s0 root root -- /system/bin/sh ${MAGISKTMP}/tvdroid-boot.sh

        """.write(to: tool.appendingPathComponent("tvdroid.rc"), atomically: true, encoding: .utf8)
        try """
        #!/system/bin/sh
        # Added by TVDroid. Lets adb shell use su without a prompt on the TV.
        MAGISK="$(dirname "$0")/magisk"
        i=0
        while [ $i -lt 30 ]; do
          if "$MAGISK" --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(2000,2,0,0,0)"; then
            "$MAGISK" resetprop tvdroid.root ready
            exit 0
          fi
          i=$((i + 1))
          sleep 2
        done
        "$MAGISK" resetprop tvdroid.root failed

        """.write(to: sbin.appendingPathComponent("tvdroid-boot.sh"), atomically: true, encoding: .utf8)
    }

    // MARK: - After each start

    /// Called after each start of the TV. Checks root, and sets up the Magisk files again after a Reset TV.
    func tvDidBoot() {
        guard !Self.emulatorArguments.isEmpty else {
            isWorking = false
            return
        }
        // A running root task (for example ad blocking) checks root itself after the restart.
        guard busyMessage == nil else { return }
        Task {
            defer { busyMessage = nil }
            do { try await prepare() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func prepare() async throws {
        busyMessage = busyMessage ?? "Checking root…"
        // Wait for the boot script. A `su` call before it would show a prompt on the TV.
        var state = ""
        for _ in 0..<60 {
            let result = await adb(["shell", "getprop", "tvdroid.root"])
            if result.ok { state = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !state.isEmpty { break }
            try await Task.sleep(for: .seconds(1))
        }
        guard state == "ready", await adb(["shell", "su", "-c", "id"]).output.contains("uid=0") else {
            isWorking = false
            throw ShellError.failed("The TV started, but root does not work. Turn Rooted TV off and on again. See ~/TVDroid/logs/root.log.")
        }
        isWorking = true
        try await setUpMagiskFiles()
        adBlocking = await runAsRoot("[ -f \(Self.hostsModule)/module.prop ] && [ ! -f \(Self.hostsModule)/remove ] && echo __ON__").output.contains("__ON__")
    }

    /// Magisk needs its files in /data/adb/magisk, for example for modules. The Magisk app does this
    /// after "Requires Additional Setup". TVDroid does the same, without the prompt and reboot.
    private func setUpMagiskFiles() async throws {
        let check = await runAsRoot("[ -x /data/adb/magisk/busybox ] && echo __READY__")
        if check.output.contains("__READY__") { return }
        let installed = await adb(["shell", "pm", "list", "packages", Self.magiskPackage])
        if !installed.output.contains("package:\(Self.magiskPackage)"), FileManager.default.fileExists(atPath: Self.magiskAPK.path) {
            busyMessage = "Installing the Magisk app…"
            _ = await adb(["install", "-r", Self.magiskAPK.path])
        }
        let result = await runAsRoot("""
        set -e
        APK=$(pm path \(Self.magiskPackage) | head -n 1 | cut -d: -f2)
        [ -n "$APK" ]
        T=/data/local/tmp/tvdroid-magisk
        rm -rf $T; mkdir -p $T; cd $T
        unzip -o -q "$APK" 'lib/arm64-v8a/*' 'assets/*.sh' 'assets/stub.apk'
        B=/data/adb/magisk
        rm -rf $B; mkdir -p $B
        for f in lib/arm64-v8a/lib*.so; do n=${f##*/lib}; cp "$f" "$B/${n%.so}"; done
        cp assets/*.sh assets/stub.apk $B/
        chmod -R 755 $B; chown -R 0:0 $B
        cd /; rm -rf $T
        echo __TVDROID_OK__
        """)
        guard result.output.contains("__TVDROID_OK__") else {
            throw ShellError.failed("Root works, but TVDroid could not set up the Magisk files: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: - Ad blocking

    nonisolated static let hostsModule = "/data/adb/modules/tvdroid-hosts"

    /// A Magisk module with a hosts file that sends ad and tracker hosts to 0.0.0.0, for all apps.
    func setAdBlocking(_ on: Bool, tv: TVController) async {
        guard isWorking, busyMessage == nil else { return }
        defer { busyMessage = nil }
        errorMessage = nil
        do {
            let wasOn = adBlocking
            if on {
                busyMessage = "Downloading the block list…"
                let (file, response) = try await URLSession.shared.download(from: Self.hostsURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ShellError.failed("TVDroid could not download the block list. Check the internet connection.")
                }
                defer { try? FileManager.default.removeItem(at: file) }
                busyMessage = "Installing the block list…"
                let remote = "/data/local/tmp/tvdroid-hosts"
                guard await adb(["push", file.path, remote]).ok else {
                    throw ShellError.failed("TVDroid could not copy the block list to the TV.")
                }
                // Writing into the same file changes the active hosts file at once (Magisk mounts it).
                let result = await runAsRoot("""
                set -e
                M=\(Self.hostsModule)
                mkdir -p $M/system/etc
                rm -f $M/remove $M/disable
                printf 'id=tvdroid-hosts\\nname=TVDroid ad blocking\\nversion=1\\nversionCode=1\\nauthor=TVDroid\\ndescription=Blocks ad and tracker hosts (StevenBlack list).\\n' > $M/module.prop
                cat \(remote) > $M/system/etc/hosts
                chmod 644 $M/system/etc/hosts
                chcon u:object_r:system_file:s0 $M/system/etc/hosts
                rm -f \(remote)
                echo __TVDROID_OK__
                """)
                guard result.output.contains("__TVDROID_OK__") else {
                    throw ShellError.failed("TVDroid could not install the block list: \(result.output)")
                }
            } else {
                _ = await runAsRoot("touch \(Self.hostsModule)/remove")
            }
            adBlocking = on
            // Magisk adds or removes the module at the next start.
            if on != wasOn {
                busyMessage = "Restarting Android…"
                try await tv.rebootAndroid()
                try await prepare()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - App backup

    /// Backs up all apps you installed, with their data (logins, settings), to ~/TVDroid/Backups/<date>.
    func backUpApps(tv: TVController) async {
        guard isWorking, busyMessage == nil else { return }
        defer { busyMessage = nil }
        errorMessage = nil
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let target = Self.backupsFolder.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        do {
            let list = await adb(["shell", "pm", "list", "packages", "-3"])
            let packages = list.output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("package:") }
                .map { String($0.dropFirst("package:".count)) }
                .filter { $0 != Self.magiskPackage }
                .sorted()
            guard !packages.isEmpty else { throw ShellError.failed("There are no apps to back up.") }
            var failed: [String] = []
            for (index, package) in packages.enumerated() {
                busyMessage = "Backing up \(index + 1) of \(packages.count): \(package)…"
                let folder = target.appendingPathComponent(package, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if await !backUp(package, to: folder) {
                    failed.append(package)
                    try? fm.removeItem(at: folder)
                }
            }
            if failed.count < packages.count {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } else {
                try? fm.removeItem(at: target)
            }
            if !failed.isEmpty {
                errorMessage = "TVDroid could not back up: \(failed.joined(separator: ", "))."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func backUp(_ package: String, to folder: URL) async -> Bool {
        let paths = await adb(["shell", "pm", "path", package]).output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
        guard !paths.isEmpty else { return false }
        for path in paths {
            guard await adb(["pull", path, folder.appendingPathComponent((path as NSString).lastPathComponent).path]).ok else { return false }
        }
        let p = Shell.quote(package)
        let remote = "/data/local/tmp/tvdroid-backup"
        let result = await runAsRoot("""
        P=\(p)
        O=\(remote)
        rm -rf $O; mkdir -p $O
        am force-stop "$P"
        for d in /data/data /data/user_de/0; do
          [ -d "$d/$P" ] || continue
          n=data; [ "$d" = /data/user_de/0 ] && n=user_de
          tar -czf "$O/$n.tgz" -C "$d" --exclude="$P/cache" --exclude="$P/code_cache" --exclude="$P/lib" "$P" || exit 1
        done
        chmod -R 755 $O
        echo __TVDROID_OK__
        """)
        let pulled = result.output.contains("__TVDROID_OK__") ? await adb(["pull", remote + "/.", folder.path]).ok : false
        _ = await adb(["shell", "rm", "-rf", remote])
        return pulled
    }

    /// Restores apps from a backup folder (one app folder, or a dated folder with many apps).
    func restoreBackup(tv: TVController) async {
        guard isWorking, busyMessage == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Self.backupsFolder
        panel.message = "Choose a backup, or one app folder in a backup."
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let chosen = panel.url, isWorking, busyMessage == nil else { return }
        busyMessage = "Restoring…"
        defer { busyMessage = nil }
        errorMessage = nil

        let fm = FileManager.default
        func isApp(_ url: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasSuffix(".apk") }
        }
        let apps = isApp(chosen) ? [chosen] :
            ((try? fm.contentsOfDirectory(at: chosen, includingPropertiesForKeys: nil)) ?? []).filter(isApp).sorted { $0.path < $1.path }
        guard !apps.isEmpty else {
            errorMessage = "This folder has no app backups."
            return
        }
        var failed: [String] = []
        for (index, folder) in apps.enumerated() {
            let package = folder.lastPathComponent
            busyMessage = "Restoring \(index + 1) of \(apps.count): \(package)…"
            if let problem = await restore(package, from: folder) { failed.append("\(package) (\(problem))") }
        }
        if !failed.isEmpty { errorMessage = "TVDroid could not restore: \(failed.joined(separator: ", "))." }
    }

    private func restore(_ package: String, from folder: URL) async -> String? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        let apks = files.filter { $0.pathExtension == "apk" }.sorted { a, b in
            let aBase = a.lastPathComponent == "base.apk", bBase = b.lastPathComponent == "base.apk"
            return aBase != bBase ? aBase : a.path < b.path
        }
        let install = await adb([apks.count > 1 ? "install-multiple" : "install", "-r", "-g"] + apks.map(\.path))
        guard install.output.contains("Success") else { return "install failed" }
        let archives = files.filter { $0.pathExtension == "tgz" }
        guard !archives.isEmpty else { return nil }
        let remote = "/data/local/tmp/tvdroid-restore"
        _ = await adb(["shell", "rm", "-rf", remote, "&&", "mkdir", "-p", remote])
        for archive in archives {
            guard await adb(["push", archive.path, remote + "/" + archive.lastPathComponent]).ok else { return "copy failed" }
        }
        // Each file gets the owner and the SELinux label of the app's folder, so the app can use it.
        let result = await runAsRoot("""
        P=\(Shell.quote(package))
        I=\(remote)
        am force-stop "$P"
        for n in data user_de; do
          [ -f "$I/$n.tgz" ] || continue
          d=/data/data; [ "$n" = user_de ] && d=/data/user_de/0
          [ -d "$d/$P" ] || exit 1
          U=$(stat -c %u "$d/$P")
          find "$d/$P" -mindepth 1 -maxdepth 1 ! -name lib -exec rm -rf {} +
          tar -xzf "$I/$n.tgz" -C "$d" || exit 1
          chown -hR "$U:$U" "$d/$P"
          chcon -hR "$(stat -c %C "$d/$P")" "$d/$P"
        done
        rm -rf "$I"
        echo __TVDROID_OK__
        """)
        return result.output.contains("__TVDROID_OK__") ? nil : "data failed"
    }

    func openBackupsFolder() {
        try? FileManager.default.createDirectory(at: Self.backupsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.backupsFolder)
    }

    // MARK: - Helpers

    private func adb(_ args: [String]) async -> ShellResult {
        await Shell.run(Tools.adb, ["-s", TVController.serial] + args)
    }

    /// Runs a shell script as root on the TV.
    private func runAsRoot(_ script: String) async -> ShellResult {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("tvdroid-root-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: local) }
        do { try script.write(to: local, atomically: true, encoding: .utf8) } catch {
            return ShellResult(status: -1, output: error.localizedDescription)
        }
        let remote = "/data/local/tmp/tvdroid-root-\(UUID().uuidString).sh"
        let push = await adb(["push", local.path, remote])
        guard push.ok else { return push }
        return await adb(["shell", "su -c 'sh \(remote)'; s=$?; rm -f \(remote); exit $s"])
    }

    private func log(_ line: String) { Self.appendLog(line) }

    nonisolated static func appendLog(_ line: String) {
        let url = logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Collects output lines from a background queue.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func last(where match: (String) -> Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        return lines.last(where: match)
    }
}
