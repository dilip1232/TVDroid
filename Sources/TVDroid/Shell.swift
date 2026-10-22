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
        case .missingTool(let name): return "\(name) is not installed. Run setup.sh first."
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
    static let sdkRoot: URL = {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["ANDROID_SDK_ROOT"], env["ANDROID_HOME"],
            "/opt/homebrew/share/android-commandlinetools",
            NSHomeDirectory() + "/Library/Android/sdk",
        ].compactMap { $0 }
        let fm = FileManager.default
        let found = candidates.first { fm.fileExists(atPath: $0 + "/emulator/emulator") }
        return URL(fileURLWithPath: found ?? candidates.last!)
    }()

    static var adb: URL { sdkRoot.appendingPathComponent("platform-tools/adb") }
    static var emulator: URL { sdkRoot.appendingPathComponent("emulator/emulator") }

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
