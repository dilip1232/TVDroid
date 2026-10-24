import Foundation

struct ShellResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

enum ShellError: LocalizedError {
    case missingTool(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let name): return "\(name) is not installed. Finish the setup in the TVDroid window first."
        case .failed(let message): return message
        }
    }
}

/// Small helpers to run command-line tools without blocking the main thread.
enum Shell {
    /// Environment for all child processes. GUI apps do not get the shell PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SDK_ROOT"] = Tools.sdkRoot.path
        env["ANDROID_HOME"] = Tools.sdkRoot.path
        env["ADB"] = Tools.adb.path
        if Tools.testHome != nil {
            // Test mode: the SDK tools and the emulator use the test folder, not ~/.android.
            env["ANDROID_USER_HOME"] = Tools.androidUserHome.path
            env["ANDROID_EMULATOR_HOME"] = Tools.androidUserHome.path
            env["ANDROID_AVD_HOME"] = Tools.avdDir.path
        }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        return env
    }

    /// Runs a tool to completion and returns stdout + stderr.
    static func run(_ tool: URL, _ args: [String]) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = args
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ShellResult(status: -1, output: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                cont.resume(returning: ShellResult(status: process.terminationStatus, output: text))
            }
        }
    }

    /// Runs a tool to completion and sends each output line to `onLine` (on a background queue).
    /// `input` is written to stdin; stdin is then closed, so a tool never waits for a terminal.
    /// Progress bars that redraw with "\r" arrive as separate lines.
    static func stream(
        _ tool: URL, _ args: [String], input: String? = nil, extraEnvironment: [String: String] = [:],
        onLine: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // A tool can exit before it reads its stdin. Then a write must fail, not kill the app.
                signal(SIGPIPE, SIG_IGN)
                let process = Process()
                process.executableURL = tool
                process.arguments = args
                process.environment = environment.merging(extraEnvironment) { $1 }
                let output = Pipe()
                let stdin = Pipe()
                process.standardOutput = output
                process.standardError = output
                process.standardInput = stdin
                do {
                    try process.run()
                } catch {
                    onLine(error.localizedDescription)
                    cont.resume(returning: -1)
                    return
                }
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()

                let reader = output.fileHandleForReading
                var pending = Data()
                func emit(_ bytes: Data) {
                    let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { onLine(line) }
                }
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        emit(pending[pending.startIndex..<index])
                        pending = Data(pending[pending.index(after: index)...])
                    }
                }
                emit(pending)
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus)
            }
        }
    }

    /// Starts a long-running tool and returns at once. Output goes to a log file.
    @discardableResult
    static func launch(_ tool: URL, _ args: [String], log: URL, onExit: (@Sendable () -> Void)? = nil) throws -> Process {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.environment = environment
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { _ in
            try? handle.close()
            onExit?()
        }
        try process.run()
        return process
    }
}

/// Paths to the Android tools.
enum Tools {
    /// Test mode: `TVDROID_TEST_HOME=/tmp/tvd-test open TVDroid.app`.
    /// The app then keeps the SDK, the TV device, the APKs and the logs in that folder.
    /// So you can test the setup without touching your real SDK and TV.
    /// Homebrew, Java and the command-line tools (sdkmanager) are still the real ones.
    static let testHome: String? = {
        guard let path = ProcessInfo.processInfo.environment["TVDROID_TEST_HOME"], !path.isEmpty else { return nil }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }()

    /// Home folder for TVDroid files: the user home, or the test folder.
    static var home: URL { URL(fileURLWithPath: testHome ?? NSHomeDirectory(), isDirectory: true) }
    static var androidUserHome: URL { home.appendingPathComponent(".android", isDirectory: true) }
    static var avdDir: URL { androidUserHome.appendingPathComponent("avd", isDirectory: true) }

    /// Default SDK folder of the Homebrew cask "android-commandlinetools".
    static let homebrewSDK = "/opt/homebrew/share/android-commandlinetools"

    /// The SDK folder. Computed every time, because the in-app setup can install the SDK while the app runs.
    /// Order: an SDK with the emulator, then an SDK with sdkmanager, then the Homebrew folder.
    static var sdkRoot: URL {
        if let testHome { return URL(fileURLWithPath: testHome).appendingPathComponent("sdk", isDirectory: true) }
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["ANDROID_SDK_ROOT"], env["ANDROID_HOME"],
            homebrewSDK,
            NSHomeDirectory() + "/Library/Android/sdk",
        ].compactMap { $0 }
        let fm = FileManager.default
        let found = candidates.first { fm.fileExists(atPath: $0 + "/emulator/emulator") }
            ?? candidates.first { fm.fileExists(atPath: $0 + "/cmdline-tools/latest/bin/sdkmanager") }
        return URL(fileURLWithPath: found ?? homebrewSDK)
    }

    static var adb: URL { sdkRoot.appendingPathComponent("platform-tools/adb") }
    static var emulator: URL { sdkRoot.appendingPathComponent("emulator/emulator") }
    static var sdkManager: URL { commandLineTool("sdkmanager") }
    static var avdManager: URL { commandLineTool("avdmanager") }

    /// sdkmanager or avdmanager: from the SDK folder, else from the Homebrew cask.
    /// Both tools can work on any SDK folder (sdkmanager --sdk_root, avdmanager reads ANDROID_SDK_ROOT).
    private static func commandLineTool(_ name: String) -> URL {
        let inSDK = sdkRoot.appendingPathComponent("cmdline-tools/latest/bin/\(name)")
        let inBrew = URL(fileURLWithPath: homebrewSDK).appendingPathComponent("cmdline-tools/latest/bin/\(name)")
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: inSDK.path) || !fm.isExecutableFile(atPath: inBrew.path) ? inSDK : inBrew
    }

    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// A Java 17 or later home folder. sdkmanager and avdmanager need Java.
    /// Homebrew installs openjdk@17 "keg-only", so java_home does not always find it.
    static func javaHome() async -> String? {
        let fm = FileManager.default
        func hasJava(_ home: String) -> Bool { fm.isExecutableFile(atPath: home + "/bin/java") }
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], hasJava(home) { return home }
        let result = await Shell.run(URL(fileURLWithPath: "/usr/libexec/java_home"), ["-v", "17+"])
        let found = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.ok, hasJava(found) { return found }
        let prefixes = ["/opt/homebrew/opt", "/usr/local/opt"]
        let kegs = ["openjdk@17", "openjdk@21", "openjdk"]
        for prefix in prefixes {
            for keg in kegs {
                let home = "\(prefix)/\(keg)/libexec/openjdk.jdk/Contents/Home"
                if hasJava(home) { return home }
            }
        }
        return nil
    }

    static var aapt2: URL? {
        let dir = sdkRoot.appendingPathComponent("build-tools")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let latest = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first
        else { return nil }
        return dir.appendingPathComponent(latest).appendingPathComponent("aapt2")
    }

    static func require(_ url: URL?, _ name: String) throws -> URL {
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ShellError.missingTool(name)
        }
        return url
    }
}
