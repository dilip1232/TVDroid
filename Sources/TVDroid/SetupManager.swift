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
            case .java: return "Java 17"
            case .commandLineTools: return "Android command-line tools"
            case .sdkPackages: return "Android emulator and Google TV image"
            case .tvDevice: return "TV device \"\(TVController.avdName)\""
            }
        }

        var detail: String {
            switch self {
            case .homebrew: return "Installs the other tools. Opens in Terminal and asks for your Mac password."
            case .java: return "Needed by the Android SDK tools."
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
    @Published private(set) var log: [String] = []

    var isComplete: Bool { Step.allCases.allSatisfy { status[$0] == .done } }

    private static var avdDir: URL { Tools.avdDir }
    nonisolated static var avdIni: URL { Tools.avdDir.appendingPathComponent("\(TVController.avdName).ini") }
    nonisolated static var avdConfig: URL { Tools.avdDir.appendingPathComponent("\(TVController.avdName).avd/config.ini") }

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

        await check()
        for step in Step.allCases where status[step] != .done {
            status[step] = .running
            append("==> \(step.title)")
            do {
                try await run(step)
                status[step] = .done
            } catch {
                status[step] = .failed(error.localizedDescription)
                append("Error: \(error.localizedDescription)")
                return
            }
        }
        await check()
        append("==> Done. Put .apk files in ~/TVDroid/APKs")
    }

    /// Opens the setup log folder in Finder.
    func revealLogs() {
        NSWorkspace.shared.open(Self.logDir)
    }

    // MARK: - Checks

    private func check() async {
        let fm = FileManager.default
        let java = await Tools.javaHome() != nil
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
        status[.java] = java ? .done : .missing
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
                "hw.ramSize": "4096",
                "hw.cpu.ncore": "4",
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
    /// TVDroid opens it in Terminal and waits until brew exists.
    private func installHomebrew() async throws {
        let script = Self.logDir.appendingPathComponent("install-homebrew.command")
        let text = """
        #!/bin/bash
        echo "TVDroid: installing Homebrew. Enter your Mac password when asked."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        echo
        echo "Done. You can close this window and go back to TVDroid."

        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else {
            throw ShellError.failed("TVDroid cannot open Terminal. Install Homebrew from https://brew.sh, then click Check Again.")
        }
        append("Opened the Homebrew installer in Terminal.")
        progress = "Waiting for the Homebrew install in Terminal…"
        // Wait up to 30 minutes.
        for _ in 0..<900 {
            if Tools.brew != nil { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw ShellError.failed("Homebrew is not installed yet. Finish the install in Terminal, then click Install again.")
    }

    // MARK: - Helpers

    private func brew() throws -> URL {
        guard let brew = Tools.brew else {
            throw ShellError.failed("Homebrew is not installed. Install it from https://brew.sh.")
        }
        return brew
    }

    private func javaEnvironment() async throws -> [String: String] {
        guard let home = await Tools.javaHome() else {
            throw ShellError.failed("Java 17 or later is not installed.")
        }
        let path = Shell.environment["PATH"] ?? ""
        return ["JAVA_HOME": home, "PATH": "\(home)/bin:\(path)"]
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
