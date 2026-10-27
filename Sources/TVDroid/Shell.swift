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
    /// Environment for all child processes.
    /// GUI apps do not get the shell environment, so TVDroid adds the variables from the user's
    /// login shell (~/.zprofile, ~/.zshrc). The SDK and Java that TVDroid uses come first in PATH.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.merging(UserShell.environment) { $1 }
        let sdk = Tools.sdkRoot.path
        env["ANDROID_SDK_ROOT"] = sdk
        env["ANDROID_HOME"] = sdk
        env["ADB"] = Tools.adb.path
        // Larger CoreAudio buffers for the emulator (default 4 x 512 frames, about 46 ms).
        // With the small buffer the sound breaks up when the Mac is busy. 4 x 1024 is about 93 ms, still fine for lip sync.
        env["QEMU_COREAUDIO_BUFFER_SIZE"] = env["QEMU_COREAUDIO_BUFFER_SIZE"] ?? "1024"
        env["QEMU_COREAUDIO_BUFFER_COUNT"] = env["QEMU_COREAUDIO_BUFFER_COUNT"] ?? "4"
        if Tools.testHome != nil {
            // Test mode: the SDK tools and the emulator use the test folder, not ~/.android.
            env["ANDROID_USER_HOME"] = Tools.androidUserHome.path
            env["ANDROID_EMULATOR_HOME"] = Tools.androidUserHome.path
            env["ANDROID_AVD_HOME"] = Tools.avdDir.path
        }
        var path = ["\(sdk)/platform-tools", "\(sdk)/emulator", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let java = Tools.cachedJava {
            env["JAVA_HOME"] = java.home
            path.insert(java.home + "/bin", at: 0)
        }
        env["PATH"] = (path + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    /// Quotes a string for a POSIX shell.
    static func quote(_ text: String) -> String {
        if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    /// Order: the folder from Settings, then an SDK with the emulator, then an SDK with sdkmanager,
    /// then the Homebrew folder. ANDROID_HOME and ANDROID_SDK_ROOT also come from the login shell.
    static var sdkRoot: URL {
        if let testHome { return URL(fileURLWithPath: testHome).appendingPathComponent("sdk", isDirectory: true) }
        if let custom = Prefs.sdkRoot { return URL(fileURLWithPath: custom, isDirectory: true) }
        let env = ProcessInfo.processInfo.environment
        let shell = UserShell.environment
        let candidates = [
            env["ANDROID_SDK_ROOT"], env["ANDROID_HOME"], shell["ANDROID_SDK_ROOT"], shell["ANDROID_HOME"],
            homebrewSDK,
            NSHomeDirectory() + "/Library/Android/sdk",
        ].compactMap { $0 }.filter { !$0.isEmpty }
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

    /// A Java runtime that the Android tools can use.
    struct Java: Equatable, Sendable {
        let home: String
        let major: Int
        /// Where TVDroid found it, for the setup screen.
        let source: String
        /// True if /usr/libexec/java_home knows it. Then `java` also works in Terminal.
        let registered: Bool

        var isSupported: Bool { major >= Tools.minimumJava }
        /// The .jdk bundle folder (…/openjdk.jdk) that a symlink in /Library/Java/JavaVirtualMachines needs.
        var bundle: String? {
            home.hasSuffix("/Contents/Home") ? String(home.dropLast("/Contents/Home".count)) : nil
        }
    }

    /// The current Android command-line tools need Java 17.
    static let minimumJava = 17

    private static let javaLock = NSLock()
    nonisolated(unsafe) private static var _cachedJava: Java?
    /// The Java that the last `findJava()` found. Shell.environment uses it for JAVA_HOME.
    static var cachedJava: Java? {
        get { javaLock.lock(); defer { javaLock.unlock() }; return _cachedJava }
        set { javaLock.lock(); _cachedJava = newValue; javaLock.unlock() }
    }

    /// Finds the best Java. Order: the folder from Settings, JAVA_HOME (app or login shell),
    /// /usr/libexec/java_home, then Homebrew kegs. Homebrew installs openjdk@17 "keg-only",
    /// so java_home and Terminal do not see it until it is linked to /Library/Java/JavaVirtualMachines.
    /// Returns the first supported Java. If there is none, returns the first Java found (too old),
    /// so that the setup can say why it does not work.
    @discardableResult
    static func findJava() async -> Java? {
        var candidates: [(String, String)] = []
        if let custom = Prefs.javaHome { candidates.append((custom, "Settings")) }
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"] { candidates.append((home, "JAVA_HOME")) }
        if let home = UserShell.environment["JAVA_HOME"] { candidates.append((home, "JAVA_HOME in your shell")) }
        let javaHome = await Shell.run(URL(fileURLWithPath: "/usr/libexec/java_home"), ["-v", "\(minimumJava)+"])
        let registeredHome = javaHome.ok ? javaHome.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } : nil
        if let registeredHome { candidates.append((registeredHome, "java_home")) }
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for keg in ["openjdk@17", "openjdk@21", "openjdk"] {
                candidates.append(("\(prefix)/\(keg)/libexec/openjdk.jdk/Contents/Home", "Homebrew \(keg)"))
            }
        }

        var tooOld: Java?
        var seen = Set<String>()
        for (home, source) in candidates where !home.isEmpty {
            let resolved = (home as NSString).resolvingSymlinksInPath
            guard seen.insert(resolved).inserted,
                  FileManager.default.isExecutableFile(atPath: home + "/bin/java"),
                  let major = await javaMajor(home) else { continue }
            let registered = await isRegistered(home)
            let java = Java(home: home, major: major, source: source, registered: registered)
            if java.isSupported {
                cachedJava = java
                return java
            }
            if tooOld == nil { tooOld = java }
        }
        cachedJava = nil
        return tooOld
    }

    /// The major version from `java -version`, for example 17 for "17.0.16" and 8 for "1.8.0_402".
    private static func javaMajor(_ home: String) async -> Int? {
        let result = await Shell.run(URL(fileURLWithPath: home + "/bin/java"), ["-version"])
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains("version \"") }),
              let start = line.range(of: "version \"") else { return nil }
        let version = line[start.upperBound...].prefix { $0 != "\"" }
        let parts = version.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        guard let first = parts.first else { return nil }
        return first == 1 && parts.count > 1 ? parts[1] : first
    }

    /// True if /usr/libexec/java_home lists this Java, so plain `java` works in Terminal.
    private static func isRegistered(_ home: String) async -> Bool {
        let result = await Shell.run(URL(fileURLWithPath: "/usr/libexec/java_home"), ["-V"])
        let target = (home as NSString).resolvingSymlinksInPath
        return result.output.split(separator: "\n").contains { line in
            guard let path = line.split(separator: " ").last.map(String.init), path.hasPrefix("/") else { return false }
            return (path as NSString).resolvingSymlinksInPath == target
        }
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

/// Settings that the user can change in the setup screen or in Settings (⌘,).
enum Prefs {
    private static let defaults = UserDefaults.standard

    /// A Java home folder that TVDroid must use. Nil: find Java automatically.
    static var javaHome: String? {
        get { clean(defaults.string(forKey: "javaHome")) }
        set { defaults.set(clean(newValue), forKey: "javaHome") }
    }

    /// An Android SDK folder that TVDroid must use. Nil: find the SDK automatically.
    static var sdkRoot: String? {
        get { clean(defaults.string(forKey: "sdkRoot")) }
        set { defaults.set(clean(newValue), forKey: "sdkRoot") }
    }

    /// The TV screen size. 1080p looks best. 720p is faster on older Macs.
    enum Resolution: String, CaseIterable, Identifiable {
        case p1080 = "1080p", p720 = "720p"
        var id: String { rawValue }
        var width: Int { self == .p1080 ? 1920 : 1280 }
        var height: Int { self == .p1080 ? 1080 : 720 }
        /// Android TV densities: xhdpi for 1080p, tvdpi for 720p. Both give the same layout.
        var density: Int { self == .p1080 ? 320 : 213 }
    }

    static var resolution: Resolution {
        get { defaults.string(forKey: "resolution").flatMap(Resolution.init) ?? .p1080 }
        set { defaults.set(newValue.rawValue, forKey: "resolution") }
    }

    /// Rooted TV (experimental): start the TV with the Magisk ramdisk. See RootManager.
    static var rootedTV: Bool {
        get { defaults.bool(forKey: "rootedTV") }
        set { defaults.set(newValue, forKey: "rootedTV") }
    }

    static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return (value as NSString).expandingTildeInPath
    }
}

/// The user's login shell and its environment.
/// Apps that start from the Dock or Finder do not read ~/.zshrc, so TVDroid asks the shell once.
enum UserShell {
    /// The login shell, for example /bin/zsh.
    static let path: String = {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }()

    static var name: String { (path as NSString).lastPathComponent }

    /// The startup file that the shell reads for each new Terminal window.
    static var rcFile: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch name {
        case "bash": return home.appendingPathComponent(".bash_profile")
        case "fish": return home.appendingPathComponent(".config/fish/config.fish")
        default: return home.appendingPathComponent(".zshrc")
        }
    }

    /// Variables that describe the shell process itself, not the user's setup.
    private static let skipped: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM",
                                               "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLUMNS", "LINES", "ZDOTDIR"]

    /// The environment of an interactive login shell. Empty if the shell fails or takes more than 8 s.
    /// Loaded once. Call `preload()` at app start, so the first tool does not wait.
    static let environment: [String: String] = load()

    static func preload() {
        DispatchQueue.global(qos: .userInitiated).async { _ = environment }
    }

    private static func load() -> [String: String] {
        if ProcessInfo.processInfo.environment["TVDROID_NO_SHELL_ENV"] != nil { return [:] }
        let marker = "__TVDROID_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // -i -l: read the same files as a new Terminal window. stdin is empty, so no prompt can wait.
        process.arguments = ["-i", "-l", "-c", "printf \(marker); /usr/bin/env -0"]
        var env = ProcessInfo.processInfo.environment
        env["TVDROID_SHELL_PROBE"] = "1"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }

        // Read on another thread: a program that the shell starts in the background can keep the pipe open.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + 8) == .success else {
            if process.isRunning { process.terminate() }
            NSLog("TVDroid: the login shell \(path) did not finish in 8 s. Using the app environment only.")
            return [:]
        }
        let data = box.data

        guard let range = data.range(of: Data(marker.utf8)) else { return [:] }
        var result: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let eq = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<eq])
            guard !key.isEmpty, !skipped.contains(key) else { continue }
            result[key] = String(text[text.index(after: eq)...])
        }
        return result
    }
}
