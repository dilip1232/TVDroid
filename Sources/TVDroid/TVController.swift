import AppKit
import Foundation

/// Controls the headless Android TV emulator and the TV screen window.
@MainActor
final class TVController: ObservableObject {
    enum State: Equatable { case off, starting, ready }

    nonisolated static let avdName = "TVDroid"
    nonisolated static let port = 5580
    nonisolated static let serial = "emulator-\(port)"

    @Published private(set) var state: State = .off
    @Published private(set) var busyItem: URL?
    @Published private(set) var busyMessage: String?
    @Published var errorMessage: String?

    private var emulatorProcess: Process?

    private static let logDir: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("TVDroid/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        Task { if await isBooted() { state = .ready } }
    }

    // MARK: - Public

    /// Starts the TV if necessary, installs the APK if it is new or changed, then opens the app.
    func open(_ item: APKItem) async {
        guard busyItem == nil else { return }
        busyItem = item.url
        defer { busyItem = nil; busyMessage = nil }

        do {
            guard let package = item.packageName else {
                throw ShellError.failed("TVDroid cannot read \(item.url.lastPathComponent). The file is not a valid APK.")
            }
            busyMessage = "Starting TV…"
            try await ensureRunning()

            if try await needsInstall(package: package, versionCode: item.versionCode) {
                busyMessage = "Installing…"
                try await install(item.url)
            }

            busyMessage = "Opening…"
            try await launch(package: package, activity: item.launchActivity, isTVApp: item.isTVApp)
            TVWindowController.shared.show(fullScreen: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the TV window. Starts the TV first if it is off.
    func showTV() async {
        busyMessage = "Starting TV…"
        defer { busyMessage = nil }
        do {
            try await ensureRunning()
            TVWindowController.shared.show(fullScreen: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        TVWindowController.shared.hide()
        // The TV runs with -no-snapshot, so "emu kill" does not save a snapshot.
        _ = await adb(["emu", "kill"])
        for _ in 0..<20 where emulatorProcess?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(500))
        }
        emulatorProcess?.terminate()
        emulatorProcess = nil
        state = .off
    }

    /// Synchronous shutdown for app termination.
    func stopSync() {
        let kill = Process()
        kill.executableURL = Tools.adb
        kill.arguments = ["-s", Self.serial, "emu", "kill"]
        try? kill.run()
        kill.waitUntilExit()
    }

    // MARK: - Emulator

    private func ensureRunning() async throws {
        if await isBooted() { state = .ready; return }

        let emulator = try Tools.require(Tools.emulator, "Android Emulator")
        let avdIni = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd/\(Self.avdName).ini")
        guard FileManager.default.fileExists(atPath: avdIni.path) else {
            throw ShellError.failed("The TV device \"\(Self.avdName)\" does not exist. Run setup.sh first.")
        }

        state = .starting
        if emulatorProcess?.isRunning != true {
            try applyResolution()
            emulatorProcess = try Shell.launch(
                emulator,
                // -share-vid: the emulator writes each frame to shared memory. TVScreen.swift shows it.
                // -no-snapshot: always cold boot (about 15 s). After a Quick Boot snapshot, the host GPU
                // can show an old buffer for new screens ("Failed to find ColorBuffer" in the log).
                ["-avd", Self.avdName, "-port", "\(Self.port)", "-gpu", "host", "-no-window", "-share-vid",
                 "-no-snapshot", "-no-boot-anim", "-netdelay", "none", "-netspeed", "full"],
                log: Self.logDir.appendingPathComponent("emulator.log"),
                onExit: { [weak self] in
                    Task { @MainActor in
                        self?.emulatorProcess = nil
                        self?.state = .off
                    }
                }
            )
        }

        // Wait up to 3 minutes for the first boot. Quick Boot usually takes a few seconds.
        for _ in 0..<180 {
            if await isBooted() {
                state = .ready
                TVWindowController.shared.reconnect()
                return
            }
            if emulatorProcess?.isRunning != true {
                state = .off
                throw ShellError.failed("The TV stopped while it was starting. See ~/TVDroid/logs/emulator.log.")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ShellError.failed("The TV did not start in 3 minutes. See ~/TVDroid/logs/emulator.log.")
    }

    private func isBooted() async -> Bool {
        let result = await adb(["shell", "getprop", "sys.boot_completed"])
        return result.ok && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // MARK: - Apps

    private func needsInstall(package: String, versionCode: Int?) async throws -> Bool {
        let result = await adb(["shell", "pm", "list", "packages", "--show-versioncode", package])
        // Output line: "package:com.example versionCode:123"
        let line = result.output.split(separator: "\n").first { $0.hasPrefix("package:\(package) ") }
        guard let line else { return true }
        guard let versionCode else { return false }
        let installed = line.components(separatedBy: "versionCode:").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return installed != versionCode
    }

    private func install(_ apk: URL) async throws {
        let result = await adb(["install", "-r", "-g", apk.path])
        guard result.output.contains("Success") else {
            let reason = result.output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("Error") }
            throw ShellError.failed(Self.explainInstallError(String(reason ?? Substring(result.output))))
        }
    }

    private func launch(package: String, activity: String?, isTVApp: Bool) async throws {
        if let activity {
            let name = activity.hasPrefix(".") ? package + activity : activity
            let result = await adb(["shell", "am", "start", "-n", "\(package)/\(name)"])
            if result.ok && !result.output.contains("Error") { return }
        }
        // Fallback: let Android pick the launcher activity.
        let category = isTVApp ? "android.intent.category.LEANBACK_LAUNCHER" : "android.intent.category.LAUNCHER"
        let result = await adb(["shell", "monkey", "-p", package, "-c", category, "1"])
        guard result.ok, !result.output.contains("No activities found") else {
            throw ShellError.failed("The app is installed, but it has no screen that TVDroid can open.")
        }
    }

    // MARK: - Screen size

    /// Writes the 1080p screen size to the AVD config. The emulator reads it at start.
    /// 4K gives no gain: streaming apps stay below 720p (Widevine L3), macOS cannot share 4K frames
    /// (kern.sysv.shmmax), and the TV gets slow.
    private func applyResolution() throws {
        let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd/\(Self.avdName).avd/config.ini")
        var lines = try String(contentsOf: config, encoding: .utf8).components(separatedBy: "\n")
        let values = [
            "hw.lcd.width": "1920",
            "hw.lcd.height": "1080",
            "hw.lcd.density": "320",
        ]
        for (key, value) in values {
            if let index = lines.firstIndex(where: { $0.hasPrefix(key + "=") }) {
                lines[index] = "\(key)=\(value)"
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        try lines.joined(separator: "\n").write(to: config, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func adb(_ args: [String]) async -> ShellResult {
        await Shell.run(Tools.adb, ["-s", Self.serial] + args)
    }

    private static func explainInstallError(_ raw: String) -> String {
        if raw.contains("INSTALL_FAILED_NO_MATCHING_ABIS") {
            return "This APK has no ARM version. The TV on this Mac runs ARM apps only."
        }
        if raw.contains("INSTALL_FAILED_OLDER_SDK") {
            return "This APK needs a newer Android version than the TV has."
        }
        if raw.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            return "An app with the same name but a different signature is installed. Uninstall it first."
        }
        if raw.contains("INSTALL_FAILED_MISSING_SPLIT") {
            return "This app is a split APK. TVDroid needs a single, complete .apk file."
        }
        return "Install failed: \(raw.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
