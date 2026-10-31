import AppKit
import AVFoundation
import Foundation

/// Controls the headless Android TV emulator and the TV screen window.
@MainActor
final class TVController: ObservableObject {
    enum State: Equatable { case off, starting, ready }

    nonisolated static let avdName = "TVDroid"
    nonisolated static let port = 5580
    nonisolated static let serial = "emulator-\(port)"

    @Published private(set) var state: State = .off {
        didSet {
            GameControllerBridge.shared.isTVOn = state == .ready
            DisplayWake.shared.isTVOn = state == .ready
            let on = state == .ready
            RemoteServer.isTVOn.withLock { $0 = on }
        }
    }
    @Published private(set) var busyItem: URL?
    @Published private(set) var busyMessage: String?
    /// Shown in the main window. While you watch the TV (or the main window is closed), on the TV window instead.
    @Published var errorMessage: String? {
        didSet {
            guard let message = errorMessage, TVWindowController.shared.showError(message) else { return }
            errorMessage = nil
        }
    }

    /// The TV window floats above other windows.
    @Published var keepTVOnTop = Prefs.keepTVOnTop {
        didSet {
            Prefs.keepTVOnTop = keepTVOnTop
            TVWindowController.shared.setOnTop(keepTVOnTop)
        }
    }

    /// An app opens or installs, or the TV starts or resets. Power buttons wait until it ends.
    var isBusy: Bool { busyItem != nil || busyMessage != nil }

    private var emulatorProcess: Process?
    /// Set while the user turns the TV off, so the exit is not reported as a crash.
    private var isStopping = false
    /// The next start erases the TV (factory reset).
    private var wipeOnNextStart = false

    private static let logDir: URL = {
        let url = Tools.home.appendingPathComponent("TVDroid/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        DisplayWake.shared.onIdle = { [weak self] in Task { await self?.turnOffUnusedTV() } }
        Task {
            if await isBooted() {
                state = .ready
                watchAdoptedTV()
                RootManager.shared.tvDidBoot()
            }
        }
    }

    // MARK: - Public

    /// Starts the TV if necessary, installs the APK if it is new or changed, then opens the app.
    func open(_ item: APKItem) async {
        guard busyItem == nil, busyMessage == nil else {
            // A second double-click on the same app is fine. Another app gets a reason.
            if busyItem != item.url { errorMessage = "TVDroid is busy: \(busyMessage ?? "working…") Try again when it is done." }
            return
        }
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
                try await install(item)
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
        // While another task starts the TV, only bring the window forward. Do not clear its progress.
        guard !isBusy else {
            if state == .ready { TVWindowController.shared.show(fullScreen: false) }
            return
        }
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
        isStopping = true
        defer { isStopping = false }
        await stopRecording()
        TVWindowController.shared.hide()
        // The TV runs with -no-snapshot, so "emu kill" does not save a snapshot.
        _ = await adb(["emu", "kill"])
        // A TV from an earlier TVDroid session has no process here. Wait for its qemu instead.
        for _ in 0..<20 {
            let running = emulatorProcess?.isRunning == true ? true : await Self.isQemuRunning()
            guard running else { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        emulatorProcess?.terminate()
        // A TV from an earlier session that ignored "emu kill": stop it, so a reset or restart really starts fresh.
        if emulatorProcess == nil, await Self.isQemuRunning() {
            _ = await Shell.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-f", Self.qemuPattern])
            try? await Task.sleep(for: .seconds(2))
        }
        emulatorProcess = nil
        state = .off
    }

    /// Battery saver: the TV had no input and no video for the time in Settings ▸ TV.
    private func turnOffUnusedTV() async {
        guard state == .ready, !isBusy, !isRecording, RootManager.shared.busyMessage == nil else { return }
        let minutes = Prefs.idleTurnOffMinutes
        await stop()
        errorMessage = "TVDroid turned off the TV after \(minutes) minutes without use, to save battery. You can change this in Settings ▸ TV."
    }

    /// Factory reset: erases all apps, accounts and settings on the TV, then starts it again.
    func resetTV() async {
        guard !isBusy else { return }
        busyMessage = "Resetting the TV…"
        defer { busyMessage = nil }
        if state != .off { await stop() }
        wipeOnNextStart = true
        do {
            try await ensureRunning()
            TVWindowController.shared.show(fullScreen: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts the TV if it is off and waits until Android is ready.
    func boot() async throws { try await ensureRunning() }

    var isEmulatorRunning: Bool { emulatorProcess?.isRunning == true }

    /// Restarts Android inside the running TV (faster than a full restart of the emulator).
    func rebootAndroid() async throws {
        _ = await adb(["reboot"])
        state = .starting
        try await Task.sleep(for: .seconds(5))
        // The TV may run from an earlier TVDroid session. Then TVDroid has no process to watch.
        try await waitForBoot(watchProcess: emulatorProcess != nil)
    }

    /// Stops the TV and starts it again, for example after a resolution change.
    func restart() async {
        guard state != .off else { return }
        await stop()
        await showTV()
    }

    // MARK: - Home app

    struct HomeApp: Identifiable, Hashable {
        let package: String
        let activity: String
        var id: String { package }
    }

    nonisolated static let googleLauncher = "com.google.android.apps.tv.launcherx"
    @Published private(set) var homeApps: [HomeApp] = []
    @Published private(set) var currentHome: String?

    /// Reads the launchers on the TV (apps with a HOME screen).
    func loadHomeApps() async {
        guard state == .ready else { homeApps = []; currentHome = nil; return }
        let query = await adb(["shell", "cmd", "package", "query-activities", "--brief",
                               "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME"])
        var apps = query.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains("FallbackHome") }
            .compactMap { line -> HomeApp? in
                let parts = line.split(separator: "/", maxSplits: 1).map(String.init)
                return parts.count == 2 ? HomeApp(package: parts[0], activity: parts[1]) : nil
            }
        // A turned-off Google TV launcher is not in the list. Show it, so the user can turn it on again.
        let disabled = await adb(["shell", "pm", "list", "packages", "-d", Self.googleLauncher])
        let googleOff = disabled.output.contains("package:\(Self.googleLauncher)")
        if googleOff, !apps.contains(where: { $0.package == Self.googleLauncher }) {
            apps.insert(HomeApp(package: Self.googleLauncher, activity: ".home.HomeActivity"), at: 0)
        }
        homeApps = apps

        let resolved = await adb(["shell", "cmd", "package", "resolve-activity", "--brief",
                                  "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME"])
        let last = resolved.output.split(separator: "\n").last.map(String.init) ?? ""
        let package = last.split(separator: "/").first.map(String.init)
        if let package, apps.contains(where: { $0.package == package }) {
            currentHome = package
        } else {
            currentHome = apps.first { $0.package != Self.googleLauncher || !googleOff }?.package
        }
    }

    /// Makes an app the home screen. Google TV ignores the "preferred home" setting while its own
    /// launcher is on, so another launcher turns the Google TV launcher off (not removed;
    /// choosing Google TV turns it on again).
    func setHome(_ package: String) async {
        guard state == .ready, let app = homeApps.first(where: { $0.package == package }) else { return }
        let component = "\(app.package)/\(app.activity)"
        if package == Self.googleLauncher {
            _ = await adb(["shell", "pm", "enable", Self.googleLauncher])
            _ = await adb(["shell", "cmd", "package", "set-home-activity", component])
        } else {
            _ = await adb(["shell", "cmd", "package", "set-home-activity", component])
            let result = await adb(["shell", "pm", "disable-user", "--user", "0", Self.googleLauncher])
            if !result.output.contains("disabled") {
                errorMessage = "TVDroid could not turn off the Google TV launcher: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        _ = await adb(["shell", "input", "keyevent", "KEYCODE_HOME"])
        await loadHomeApps()
    }

    // MARK: - Screenshot and recording

    @Published private(set) var isRecording = false
    private var recorder: Process?
    /// Each recording has its own files on the TV, so a quick stop and start cannot delete the new one.
    private var recordingID = ""
    /// The parts on the TV, in order. A new part starts every 3 minutes.
    private var recordingParts: [String] = []

    /// Where screenshots and recordings go.
    static var captureFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? Tools.home
    }

    private static func captureURL(_ kind: String, _ ext: String) -> URL {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return captureFolder.appendingPathComponent("TVDroid \(kind) \(format.string(from: Date())).\(ext)")
    }

    /// Saves a PNG of the TV screen to the Desktop and shows it in Finder.
    func screenshot() async {
        guard state == .ready else { return }
        let url = Self.captureURL("Screenshot", "png")
        let serial = Self.serial
        let data: Data? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = Tools.adb
                process.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
                process.environment = Shell.environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
        // A PNG starts with 0x89 "PNG".
        guard let data, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            errorMessage = "TVDroid could not take a screenshot of the TV."
            return
        }
        do {
            try data.write(to: url)
            Self.reveal(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts or stops a screen recording. Android stops each recording after 3 minutes, so TVDroid
    /// starts the next part at once and joins all parts into one file at the end.
    /// Protected video (Netflix and others) shows black, as on a real TV.
    func toggleRecording() async {
        if isRecording { await stopRecording(); return }
        guard state == .ready else { return }
        recordingID = String(UUID().uuidString.prefix(8))
        recordingParts = []
        isRecording = true
        startRecordingPart()
    }

    private func startRecordingPart() {
        let remote = "/sdcard/tvdroid-recording-\(recordingID)-\(recordingParts.count + 1).mp4"
        let process = Process()
        process.executableURL = Tools.adb
        process.arguments = ["-s", Self.serial, "shell", "screenrecord", "--bit-rate", "8000000", remote]
        process.environment = Shell.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.recorder === process else { return }
                // A part that ends by itself after minutes hit Android's limit: record the next part.
                // One that ends at once failed (for example the TV stopped): save what there is.
                if Date().timeIntervalSince(started) > 60 {
                    self.startRecordingPart()
                } else {
                    await self.stopRecording()
                }
            }
        }
        do { try process.run() } catch {
            errorMessage = error.localizedDescription
            recorder = nil
            // Save the parts that are already recorded.
            if recordingParts.isEmpty { isRecording = false } else { Task { await stopRecording() } }
            return
        }
        recordingParts.append(remote)
        recorder = process
    }

    private func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        let process = recorder
        recorder = nil
        // Read the paths now: a new recording can start during the waits below and gets new paths.
        let parts = recordingParts
        let id = recordingID
        // SIGINT lets screenrecord finish the MP4 file. Killing the local adb would leave it broken.
        // Stop only this recording, not a new one that started meanwhile.
        _ = await adb(["shell", "pkill", "-INT", "-f", "tvdroid-recording-\(id)"])
        for _ in 0..<20 where process?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        process?.terminate()
        try? await Task.sleep(for: .milliseconds(500))

        let url = Self.captureURL("Recording", "mp4")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tvdroid-recording-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var local: [URL] = []
        var failure: String?
        for remote in parts {
            let file = folder.appendingPathComponent((remote as NSString).lastPathComponent)
            let pull = await adb(["pull", remote, file.path], timeout: 120)
            if pull.ok { local.append(file) } else { failure = pull.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        // A part stopped right after it started has no video. Leave it out.
        var playable: [URL] = []
        for file in local {
            if let duration = try? await AVURLAsset(url: file).load(.duration), duration.seconds > 0 { playable.append(file) }
        }
        guard !playable.isEmpty else {
            errorMessage = "TVDroid could not save the recording: \(failure ?? "no video")"
            return
        }
        var saved: [URL] = []
        do {
            if playable.count == 1 {
                try FileManager.default.moveItem(at: playable[0], to: url)
            } else {
                try await Self.join(playable, to: url)
            }
            saved = [url]
        } catch {
            // Joining failed: keep each part as its own file rather than lose the video.
            for (index, file) in playable.enumerated() {
                let target = Self.captureURL("Recording part \(index + 1)", "mp4")
                if (try? FileManager.default.moveItem(at: file, to: target)) != nil { saved.append(target) }
            }
            errorMessage = "TVDroid could not join the recording parts, so it saved them as separate files: \(error.localizedDescription)"
        }
        // Delete the files on the TV only when the video is safe on the Mac.
        if !saved.isEmpty { _ = await adb(["shell", "rm", "-f"] + parts) }
        if let first = saved.first { Self.reveal(first) }
    }

    /// Joins the recording parts into one MP4 without encoding them again.
    private static func join(_ parts: [URL], to url: URL) async throws {
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            let duration = try await asset.load(.duration)
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            cursor = cursor + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ShellError.failed("macOS cannot join the recording parts.")
        }
        export.outputURL = url
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? ShellError.failed("macOS cannot join the recording parts.")
        }
    }

    /// Shows a saved file in Finder. Not while the TV is full screen: Finder would take you out of it.
    private static func reveal(_ url: URL) {
        guard !TVWindowController.shared.isFullScreen else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Synchronous shutdown for app termination.
    /// "emu kill" fails while the TV is still starting (no console yet). Then stop the emulator processes.
    func stopSync() {
        // Save a running recording first. Quitting must not lose it.
        if isRecording {
            isRecording = false
            Self.runSync(Tools.adb, ["-s", Self.serial, "shell", "pkill", "-INT", "-f", "tvdroid-recording-\(recordingID)"])
            for _ in 0..<20 where recorder?.isRunning == true { Thread.sleep(forTimeInterval: 0.25) }
            recorder?.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            // No time to join parts while quitting. Each part is saved as its own file.
            for (index, remote) in recordingParts.enumerated() {
                let name = recordingParts.count > 1 ? "Recording part \(index + 1)" : "Recording"
                Self.runSync(Tools.adb, ["-s", Self.serial, "pull", remote, Self.captureURL(name, "mp4").path], timeout: 30)
            }
        }
        Self.runSync(Tools.adb, ["-s", Self.serial, "emu", "kill"])
        for _ in 0..<20 where Self.runSync(Self.pgrep, ["-f", Self.qemuPattern]) == 0 {
            Thread.sleep(forTimeInterval: 0.25)
        }
        emulatorProcess?.terminate()
        Self.runSync(URL(fileURLWithPath: "/usr/bin/pkill"), ["-f", Self.qemuPattern])
    }

    /// Runs a tool and waits. A stuck adb must not hang Quit, so it stops after `timeout` seconds.
    @discardableResult
    private static func runSync(_ tool: URL, _ args: [String], timeout: TimeInterval = 5) -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return -1 }
        return process.terminationStatus
    }

    // MARK: - Emulator

    private func ensureRunning() async throws {
        if await isBooted() {
            state = .ready
            watchAdoptedTV()
            return
        }

        let emulator = try Tools.require(Tools.emulator, "Android Emulator")
        guard FileManager.default.fileExists(atPath: SetupManager.avdIni.path) else {
            throw ShellError.failed("The TV device \"\(Self.avdName)\" does not exist. Finish the setup in the TVDroid window first.")
        }

        state = .starting
        // A TV that an earlier TVDroid session started may still be booting. Wait for it, do not start a second one.
        var adopted = false
        if emulatorProcess?.isRunning != true { adopted = await Self.isQemuRunning() }
        if emulatorProcess?.isRunning != true, !adopted {
            try applyResolution()
            await removeStaleLocks()
            RootManager.restoreStockRamdisk()
            // -share-vid: the emulator writes each frame to shared memory. TVScreen.swift shows it.
            // -no-snapshot: always cold boot (about 15 s). After a Quick Boot snapshot, the host GPU
            // can show an old buffer for new screens ("Failed to find ColorBuffer" in the log).
            var args = ["-avd", Self.avdName, "-port", "\(Self.port)", "-gpu", "host", "-no-window", "-share-vid",
                        "-no-snapshot", "-no-boot-anim", "-netdelay", "none", "-netspeed", "full",
                        // Public DNS: the emulator copies the Mac's DNS servers at start. VPN or
                        // office servers (and network changes later) then break all name lookups.
                        "-dns-server", "1.1.1.1,8.8.8.8"]
            args += RootManager.emulatorArguments
            if wipeOnNextStart {
                args.append("-wipe-data")
                wipeOnNextStart = false
            }
            // The exit handler of an old process can run after a new start. Then it must not touch the new one.
            let box = ProcessBox()
            emulatorProcess = try Shell.launch(
                emulator,
                args,
                log: Self.logDir.appendingPathComponent("emulator.log"),
                onExit: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.emulatorProcess == nil || self.emulatorProcess === box.process else { return }
                        self.emulatorDidExit()
                    }
                }
            )
            box.process = emulatorProcess
        }

        try await waitForBoot(watchProcess: !adopted)
        if adopted { watchAdoptedTV() }
    }

    /// The emulator exited. Unless the user turned the TV off, say that it stopped.
    private func emulatorDidExit() {
        let unexpected = state == .ready && !isStopping
        emulatorProcess = nil
        state = .off
        guard unexpected else { return }
        TVWindowController.shared.hide()
        errorMessage = "The TV stopped unexpectedly. See ~/TVDroid/logs/emulator.log."
    }

    private var adoptedWatcher: Task<Void, Never>?

    /// TVDroid gets no exit callback for a TV from an earlier session. Check every few seconds that it still runs.
    private func watchAdoptedTV() {
        guard emulatorProcess == nil, adoptedWatcher == nil else { return }
        adoptedWatcher = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.emulatorProcess == nil, self.state != .off else { break }
                if self.state == .ready, !(await Self.isQemuRunning()) {
                    self.emulatorDidExit()
                    break
                }
            }
            self?.adoptedWatcher = nil
        }
    }

    private nonisolated static let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
    private nonisolated static let qemuPattern = "qemu-system.*-avd \(avdName)( |$)"

    /// True while an emulator for the TV device runs on this Mac, also one TVDroid did not start.
    private nonisolated static func isQemuRunning() async -> Bool {
        await Shell.run(pgrep, ["-f", qemuPattern]).ok
    }

    /// Waits up to 3 minutes for the first boot. A cold boot usually takes about 15 seconds.
    /// - Parameter watchProcess: stop when the emulator process that TVDroid started exits.
    private func waitForBoot(watchProcess: Bool = true) async throws {
        for _ in 0..<180 {
            if await isBooted() {
                state = .ready
                TVWindowController.shared.reconnect()
                RootManager.shared.tvDidBoot()
                return
            }
            if watchProcess, emulatorProcess?.isRunning != true {
                state = .off
                throw ShellError.failed(Self.explainEmulatorExit())
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ShellError.failed("The TV did not start in 3 minutes. See ~/TVDroid/logs/emulator.log.")
    }

    /// A crashed emulator leaves *.lock files in the AVD folder. Then the next start fails with
    /// "Another emulator instance is running". Remove them when no emulator uses this AVD.
    private func removeStaleLocks() async {
        guard !(await Self.isQemuRunning()) else { return }
        let dir = Tools.avdDir.appendingPathComponent("\(Self.avdName).avd")
        let fm = FileManager.default
        let files = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for url in files where url.pathExtension == "lock" {
            try? fm.removeItem(at: url)
        }
    }

    /// A short reason from the end of emulator.log.
    private static func explainEmulatorExit() -> String {
        let log = (try? String(contentsOf: logDir.appendingPathComponent("emulator.log"), encoding: .utf8)) ?? ""
        if log.contains("Another emulator instance is running") || log.contains("is already running") {
            return "Another emulator uses the TV device. Quit the other emulator (or Android Studio), then try again."
        }
        if log.contains("Not enough space") || log.contains("No space left") {
            return "The disk is full. Free some space, then try again."
        }
        let last = log.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("FATAL") }
        let reason = last.map { " " + $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return "The TV stopped while it was starting.\(reason) See ~/TVDroid/logs/emulator.log."
    }

    private func isBooted() async -> Bool {
        // A wedged emulator (for example after the Mac slept) can make adb hang. Then the TV is not ready.
        let result = await Shell.run(Tools.adb, ["-s", Self.serial, "shell", "getprop", "sys.boot_completed"], timeout: 10)
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

    /// Installs one APK, or all APKs of a bundle (.xapk, .apks, .apkm) together. Then copies game data (OBB).
    private func install(_ item: APKItem) async throws {
        let files = item.installFiles.isEmpty ? [item.url] : item.installFiles
        let command = files.count > 1 ? "install-multiple" : "install"
        // A large game takes a few minutes. A stuck install must not keep the app busy forever.
        let result = await adb([command, "-r", "-g"] + files.map(\.path), timeout: 15 * 60)
        if result.timedOut {
            throw ShellError.failed("The install took more than 15 minutes and was stopped. Restart the TV, then try again.")
        }
        guard result.output.contains("Success") else {
            let reason = result.output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("Error") }
            throw ShellError.failed(Self.explainInstallError(String(reason ?? Substring(result.output))))
        }
        for obb in item.obbFiles {
            busyMessage = "Copying game data…"
            let remote = "/sdcard/" + obb.remote
            let folder = (remote as NSString).deletingLastPathComponent
            _ = await adb(["shell", "mkdir", "-p", Shell.quote(folder)])
            let push = await adb(["push", obb.local.path, remote], timeout: 30 * 60)
            guard push.ok else {
                throw ShellError.failed("The app is installed, but TVDroid could not copy its game data: \(push.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Removes the app from the TV. The APK file stays in the library.
    func uninstall(_ item: APKItem) async {
        guard let package = item.packageName, busyItem == nil else { return }
        busyItem = item.url
        busyMessage = "Uninstalling…"
        defer { busyItem = nil; busyMessage = nil }
        do {
            try await ensureRunning()
            let result = await adb(["uninstall", package])
            guard result.output.contains("Success") else {
                if result.output.contains("DELETE_FAILED_INTERNAL_ERROR") || result.output.contains("Unknown package") {
                    throw ShellError.failed("\(item.label) is not installed on the TV.")
                }
                throw ShellError.failed("Uninstall failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            // Removing the chosen home app would leave the TV without a home screen. Turn Google TV on again.
            let disabled = await adb(["shell", "pm", "list", "packages", "-d", Self.googleLauncher])
            if package != Self.googleLauncher, disabled.output.contains("package:\(Self.googleLauncher)") {
                await loadHomeApps()
                if homeApps.map(\.package) == [Self.googleLauncher] { await setHome(Self.googleLauncher) }
            }
        } catch {
            errorMessage = error.localizedDescription
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
        let size = Prefs.resolution
        try SetupManager.writeConfig([
            "hw.lcd.width": "\(size.width)",
            "hw.lcd.height": "\(size.height)",
            "hw.lcd.density": "\(size.density)",
        ])
    }

    // MARK: - Helpers

    private func adb(_ args: [String], timeout: TimeInterval? = nil) async -> ShellResult {
        await Shell.run(Tools.adb, ["-s", Self.serial] + args, timeout: timeout)
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
            return "This app is a split APK and parts are missing. Use the complete .xapk, .apks or .apkm file instead."
        }
        return "Install failed: \(raw.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Holds the emulator process for its exit handler.
private final class ProcessBox: @unchecked Sendable {
    var process: Process?
}
