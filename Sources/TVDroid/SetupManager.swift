import AppKit
import Foundation

/// Checks and installs everything that the TV needs, from inside the app.
/// It does the same steps as setup.sh: Homebrew, Java, the Android command-line tools,
/// the emulator with the Google TV image, and the "TVDroid" TV device (AVD).
@MainActor
final class SetupManager: ObservableObject {
    enum Step: String, CaseIterable, Identifiable {
        case homebrew, java, commandLineTools, sdkPackages, tvDevice

        var id: String { rawValue }

        var title: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .java: return "Java 17 or later"
            case .commandLineTools: return "Android command-line tools"
            case .sdkPackages: return "Android emulator and Google TV image"
            case .tvDevice: return "TV device \"\(TVController.avdName)\""
            }
        }

        var detail: String {
            switch self {
            case .homebrew: return "Installs the other tools. Opens in Terminal and asks for your Mac password."
            case .java: return "Needed by sdkmanager and avdmanager."
            case .commandLineTools: return "sdkmanager and avdmanager."
            case .sdkPackages: return "Emulator, platform-tools, build-tools and the Android 14 Google TV image (about 2 GB)."
            case .tvDevice: return "A 1080p Android TV with 4 GB of RAM and a 16 GB disk."
            }
        }
    }

    enum Status: Equatable {
        case checking, missing, running, done
        case failed(String)
    }

    nonisolated static let systemImage = "system-images;android-34;google-tv;arm64-v8a"
    nonisolated static let packages = ["platform-tools", "emulator", "build-tools;34.0.0", systemImage]

    @Published private(set) var status: [Step: Status] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .checking) })
    @Published private(set) var hasChecked = false
    @Published private(set) var isWorking = false
    /// The last output line of the running tool, for example a download progress bar.
    @Published private(set) var progress: String?
    /// True while TVDroid waits for the Homebrew installer in Terminal. "Stop Waiting" sets it to false.
    @Published private(set) var isWaitingForHomebrew = false
    @Published private(set) var log: [String] = []
    /// The Java that the last check found. It can be too old.
    @Published private(set) var java: Tools.Java?
    /// The last step that failed. The setup screen offers to run its command in Terminal.
    @Published private(set) var failedStep: Step?
    @Published private(set) var shellProfileInstalled = ShellProfile.isInstalled
    /// A message for the Settings area, for example after "Register Java".
    @Published var notice: String?

    var isComplete: Bool { Step.allCases.allSatisfy { status[$0] == .done } }

    private static var avdDir: URL { Tools.avdDir }
    nonisolated static var avdIni: URL { Tools.avdDir.appendingPathComponent("\(TVController.avdName).ini") }
    nonisolated static var avdConfig: URL { Tools.avdDir.appendingPathComponent("\(TVController.avdName).avd/config.ini") }

    /// CPU cores for the TV: half of the Mac's cores, 4 to 8. More cores give software video decoders
    /// (AV1, VP9) and app starts more headroom.
    nonisolated static var tvCores: Int { min(8, max(4, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    /// RAM for the TV in MB: 6 GB on Macs with 16 GB or more, else 4 GB.
    nonisolated static var tvRAM: Int { ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 6144 : 4096 }

    init() {
        Task { await refresh() }
    }

    // MARK: - Public

    /// Checks every step again.
    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false; hasChecked = true }
        await check()
    }

    /// Installs all missing steps in order. Stops at the first error.
    func install() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false; progress = nil }
        log.removeAll()
        failedStep = nil

        await check()
        for step in Step.allCases where status[step] != .done {
            status[step] = .running
            append("==> \(step.title)")
            do {
                try await run(step)
                status[step] = .done
            } catch {
                status[step] = .failed(error.localizedDescription)
                failedStep = step
                append("Error: \(error.localizedDescription)")
                append("Tip: click \"Open in Terminal\" to edit the command and run it yourself.")
                return
            }
        }
        await check()
        append("==> Done. Put .apk files in ~/TVDroid/APKs")
    }

    /// Opens the command of a step in Terminal, in the user's login shell with TVDroid's variables.
    /// The command is ready to edit. After it works, click Check Again.
    func openInTerminal(_ step: Step) {
        do {
            try TerminalLauncher.open(commandLine(for: step), run: false, title: step.title)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Copies the command of a step to the clipboard.
    func copyCommand(_ step: Step) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commandLine(for: step), forType: .string)
        notice = "Copied the command for \(step.title)."
    }

    /// Opens an empty Terminal window with TVDroid's JAVA_HOME, ANDROID_HOME and PATH.
    func openShell() {
        do {
            try TerminalLauncher.open("sdkmanager --list_installed", run: false, title: "Android SDK shell")
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Adds JAVA_HOME, ANDROID_HOME and PATH to ~/.zshrc, so Terminal finds the same tools.
    func installShellProfile() {
        do {
            try ShellProfile.install()
            shellProfileInstalled = true
            notice = "Updated \(UserShell.rcFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Open a new Terminal window to use it."
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Links a Homebrew Java into /Library/Java/JavaVirtualMachines, as `brew info openjdk@17` suggests.
    /// Then /usr/libexec/java_home and `java` in Terminal find it. Asks for the Mac password.
    func registerJava() async {
        guard let java, let bundle = java.bundle else { return }
        let target = "/Library/Java/JavaVirtualMachines/openjdk-\(java.major).jdk"
        let command = "mkdir -p /Library/Java/JavaVirtualMachines && ln -sfn \(Shell.quote(bundle)) \(Shell.quote(target))"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await Shell.run(URL(fileURLWithPath: "/usr/bin/osascript"),
                                     ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        if result.ok {
            notice = "Java \(java.major) is now registered. Terminal finds it with /usr/libexec/java_home."
        } else if !result.output.contains("User canceled") {
            notice = "Cannot register Java: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        await refresh()
    }

    /// Saves the Java and SDK folders from Settings, then checks again. Empty means automatic.
    func saveOverrides(javaHome: String, sdkRoot: String) async {
        if let path = Prefs.clean(javaHome), !FileManager.default.isExecutableFile(atPath: path + "/bin/java") {
            notice = "There is no bin/java in \(path). Choose the folder that contains bin/java (…/Contents/Home)."
            return
        }
        Prefs.javaHome = javaHome
        Prefs.sdkRoot = sdkRoot
        notice = nil
        await refresh()
    }

    /// The shell command that does the same as the step. Used for Terminal and Copy.
    func commandLine(for step: Step) -> String {
        let q = Shell.quote
        switch step {
        case .homebrew:
            return "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        case .java:
            return "brew install openjdk@17"
        case .commandLineTools:
            return "brew install --cask android-commandlinetools"
        case .sdkPackages:
            let sdkManager = q(Tools.sdkManager.path)
            let root = q("--sdk_root=\(Tools.sdkRoot.path)")
            return "yes | \(sdkManager) \(root) --licenses && \(sdkManager) \(root) --install "
                + Self.packages.map(q).joined(separator: " ")
        case .tvDevice:
            return "echo no | \(q(Tools.avdManager.path)) create avd --force -n \(TVController.avdName) -k \(q(Self.systemImage)) -d tv_1080p"
        }
    }

    /// Opens the setup log folder in Finder.
    func revealLogs() {
        NSWorkspace.shared.open(Self.logDir)
    }

    // MARK: - Checks

    private func check() async {
        let fm = FileManager.default
        let found = await Tools.findJava()
        self.java = found
        let java = found?.isSupported == true
        let tools = fm.isExecutableFile(atPath: Tools.sdkManager.path) && fm.isExecutableFile(atPath: Tools.avdManager.path)
        let image = Tools.sdkRoot.appendingPathComponent("system-images/android-34/google-tv/arm64-v8a/system.img")
        let sdk = fm.isExecutableFile(atPath: Tools.emulator.path)
            && fm.isExecutableFile(atPath: Tools.adb.path)
            && Tools.aapt2.map { fm.isExecutableFile(atPath: $0.path) } == true
            && fm.fileExists(atPath: image.path)
        let avd = fm.fileExists(atPath: Self.avdIni.path)
            && fm.fileExists(atPath: Self.avdConfig.path)

        // Homebrew is only needed to install Java and the command-line tools.
        status[.homebrew] = Tools.brew != nil || (java && tools) ? .done : .missing
        if let found, !found.isSupported {
            status[.java] = .failed("Java \(found.major) at \(found.home) is too old. TVDroid needs Java \(Tools.minimumJava) or later.")
        } else {
            status[.java] = java ? .done : .missing
        }
        shellProfileInstalled = ShellProfile.isInstalled
        status[.commandLineTools] = tools ? .done : .missing
        status[.sdkPackages] = sdk ? .done : .missing
        status[.tvDevice] = avd ? .done : .missing
    }

    // MARK: - Install steps

    private func run(_ step: Step) async throws {
        switch step {
        case .homebrew:
            try await installHomebrew()

        case .java:
            try await stream(try brew(), ["install", "openjdk@17"])

        case .commandLineTools:
            try await stream(try brew(), ["install", "--cask", "android-commandlinetools"])

        case .sdkPackages:
            let sdkManager = try Tools.require(Tools.sdkManager, "sdkmanager")
            let env = try await javaEnvironment()
            try Self.checkFreeSpace(at: Tools.sdkRoot, needGB: 8)
            let root = "--sdk_root=\(Tools.sdkRoot.path)"
            // Same as "yes | sdkmanager --licenses".
            let yes = String(repeating: "y\n", count: 50)
            try await stream(sdkManager, [root, "--licenses"], input: yes, env: env)
            try await stream(sdkManager, [root, "--install"] + Self.packages, input: yes, env: env)

        case .tvDevice:
            let avdManager = try Tools.require(Tools.avdManager, "avdmanager")
            let env = try await javaEnvironment()
            if !FileManager.default.fileExists(atPath: Self.avdIni.path) || !FileManager.default.fileExists(atPath: Self.avdConfig.path) {
                // "no": do not create a custom hardware profile.
                try await stream(avdManager, ["create", "avd", "--force", "-n", TVController.avdName,
                                              "-k", Self.systemImage, "-d", "tv_1080p"], input: "no\n", env: env)
            }
            try Self.writeConfig([
                "hw.lcd.width": "1920",
                "hw.lcd.height": "1080",
                "hw.initialOrientation": "landscape",
                "hw.gpu.enabled": "yes",
                "hw.gpu.mode": "host",
                "hw.ramSize": "\(Self.tvRAM)",
                "hw.cpu.ncore": "\(Self.tvCores)",
                "hw.keyboard": "yes",
                "showDeviceFrame": "no",
                "hw.audioOutput": "yes",
                "disk.dataPartition.size": "16G",
                "fastboot.forceColdBoot": "no",
            ])
            try FileManager.default.createDirectory(at: APKLibrary.folder, withIntermediateDirectories: true)
        }
    }

    /// The official Homebrew installer needs a terminal (it asks for the password with sudo).
    /// TVDroid opens it in Terminal, in the user's login shell, and waits until brew exists.
    private func installHomebrew() async throws {
        try TerminalLauncher.open(commandLine(for: .homebrew), run: true, title: "Install Homebrew. Enter your Mac password when asked.")
        append("Opened the Homebrew installer in Terminal.")
        progress = "Waiting for the Homebrew install in Terminal…"
        isWaitingForHomebrew = true
        defer { isWaitingForHomebrew = false }
        // Wait up to 30 minutes, or until the user stops waiting (for example after closing Terminal).
        for _ in 0..<900 {
            if Tools.brew != nil { return }
            guard isWaitingForHomebrew else { break }
            try await Task.sleep(for: .seconds(2))
        }
        throw ShellError.failed("Homebrew is not installed yet. Finish the install in Terminal, then click Install again.")
    }

    func stopWaitingForHomebrew() { isWaitingForHomebrew = false }

    // MARK: - Helpers

    private func brew() throws -> URL {
        guard let brew = Tools.brew else {
            throw ShellError.failed("Homebrew is not installed. Install it from https://brew.sh.")
        }
        return brew
    }

    private func javaEnvironment() async throws -> [String: String] {
        guard let java = await Tools.findJava(), java.isSupported else {
            throw ShellError.failed("Java \(Tools.minimumJava) or later is not installed. Install it, or choose its folder in Advanced.")
        }
        append("Using Java \(java.major) from \(java.home) (\(java.source))")
        // Shell.environment adds JAVA_HOME and PATH from Tools.cachedJava.
        return ["JAVA_HOME": java.home]
    }

    /// Throws if the disk has less free space than the download and the TV need.
    nonisolated static func checkFreeSpace(at url: URL, needGB: Int) throws {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        let freeGB = Double(free) / 1_000_000_000
        if freeGB < Double(needGB) {
            throw ShellError.failed(String(format: "Only %.1f GB is free on the disk. TVDroid needs about %d GB. Free some space, then click Install again.", freeGB, needGB))
        }
    }

    /// Runs a tool, shows its output, and throws if it fails.
    private func stream(_ tool: URL, _ args: [String], input: String? = nil, env: [String: String] = [:]) async throws {
        append("$ \(tool.lastPathComponent) \(args.joined(separator: " "))")
        var extra = env
        // Homebrew: no auto-update and no hints, so the install is faster and the log is short.
        extra["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        extra["HOMEBREW_NO_ENV_HINTS"] = "1"
        extra["NONINTERACTIVE"] = "1"
        let status = await Shell.stream(tool, args, input: input, extraEnvironment: extra) { line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(line) } }
        }
        // The output lines are queued on the main queue before this point. Let them arrive first.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { cont.resume() } }
        guard status == 0 else {
            let last = log.last { !$0.hasPrefix("$ ") && !$0.hasPrefix("==>") } ?? ""
            throw ShellError.failed("\(tool.lastPathComponent) failed (exit code \(status)). \(last)")
        }
    }

    private func receive(_ line: String) {
        progress = line
        // sdkmanager redraws its progress bar ("[=====    ] 45% Downloading…"). Keep it out of the log.
        if line.hasPrefix("[") { return }
        append(line)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
        if let data = (line + "\n").data(using: .utf8), let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private static let logDir: URL = {
        let url = Tools.home.appendingPathComponent("TVDroid/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let logFile: URL = {
        let url = logDir.appendingPathComponent("setup.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    /// Sets keys in the AVD config.ini. Adds keys that are not there.
    nonisolated static func writeConfig(_ values: [String: String]) throws {
        var lines = try String(contentsOf: avdConfig, encoding: .utf8).components(separatedBy: "\n")
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            if let index = lines.firstIndex(where: { $0.hasPrefix(key + "=") }) {
                lines[index] = "\(key)=\(value)"
            } else {
                if lines.last == "" { lines.removeLast() }
                lines.append("\(key)=\(value)")
                lines.append("")
            }
        }
        try lines.joined(separator: "\n").write(to: avdConfig, atomically: true, encoding: .utf8)
    }
}
