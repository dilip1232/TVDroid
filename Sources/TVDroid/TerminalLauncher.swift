import AppKit
import Foundation

/// Opens a command in Terminal, in the user's own login shell (zsh reads ~/.zshrc as usual).
/// TVDroid's JAVA_HOME, ANDROID_HOME and PATH are set after the user's files, so the command
/// sees the same tools as the app. The window stays open, so the user can edit and run it again.
enum TerminalLauncher {
    /// - Parameters:
    ///   - command: shell command line.
    ///   - run: true runs the command at once. False puts it on the command line to edit (zsh),
    ///     or copies it to the clipboard (other shells).
    ///   - title: shown at the top of the window.
    static func open(_ command: String, run: Bool, title: String) throws {
        let dir = Tools.home.appendingPathComponent("TVDroid/logs/terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("tvdroid.command")

        let exports = environmentExports()
        let text: String
        if UserShell.name == "zsh" {
            // zsh reads $ZDOTDIR/.zshrc. TVDroid's .zshrc reads the user's files first, then adds the
            // TVDroid variables and puts the command on the edit line with `print -z`.
            let zdot = dir.appendingPathComponent("zsh", isDirectory: true)
            try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
            try """
            [[ -f "$HOME/.zshenv" ]] && source "$HOME/.zshenv"

            """.write(to: zdot.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try """
            [[ -f "$HOME/.zprofile" ]] && source "$HOME/.zprofile"

            """.write(to: zdot.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
            try """
            HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
            [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
            ZDOTDIR="$HOME"
            \(exports)
            print -P "%B==> TVDroid: \(title.replacingOccurrences(of: "\"", with: "'"))%b"
            print "JAVA_HOME=$JAVA_HOME"
            print "ANDROID_HOME=$ANDROID_HOME"
            if [[ -n "$TVDROID_RUN" ]]; then
              print -s -- "$TVDROID_CMD"
              print -- "$ $TVDROID_CMD"
              eval "$TVDROID_CMD"
            else
              print "Edit the command below, then press Return. Then click Check Again in TVDroid."
              print -z -- "$TVDROID_CMD"
            fi
            unset TVDROID_CMD TVDROID_RUN

            """.write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            text = """
            #!/bin/zsh
            export TVDROID_CMD=\(Shell.quote(command))
            \(run ? "export TVDROID_RUN=1" : "unset TVDROID_RUN")
            export ZDOTDIR=\(Shell.quote(zdot.path))
            exec \(Shell.quote(UserShell.path)) -il

            """
        } else {
            if !run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            text = """
            #!/bin/bash
            [ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
            \(exports)
            echo "==> TVDroid: \(title.replacingOccurrences(of: "\"", with: "'"))"
            echo "JAVA_HOME=$JAVA_HOME"
            echo "ANDROID_HOME=$ANDROID_HOME"
            CMD=\(Shell.quote(command))
            \(run ? "echo \"$ $CMD\"; eval \"$CMD\"" : "echo \"The command is in the clipboard. Paste it with Cmd-V, edit it, then press Return:\"; echo \"  $CMD\"")
            exec bash

            """
        }
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: config)
        } else if !NSWorkspace.shared.open(script) {
            throw ShellError.failed("TVDroid cannot open Terminal. Run this command yourself:\n\(command)")
        }
    }

    /// `export` lines for the variables that TVDroid uses. Also used for "Add to ~/.zshrc".
    static func environmentExports() -> String {
        let sdk = Tools.sdkRoot.path
        var lines: [String] = []
        var path: [String] = []
        if let java = Tools.cachedJava {
            lines.append("export JAVA_HOME=\(Shell.quote(java.home))")
            path.append("$JAVA_HOME/bin")
        }
        lines.append("export ANDROID_HOME=\(Shell.quote(sdk))")
        lines.append("export ANDROID_SDK_ROOT=\"$ANDROID_HOME\"")
        path += ["$ANDROID_HOME/cmdline-tools/latest/bin", "$ANDROID_HOME/platform-tools", "$ANDROID_HOME/emulator"]
        if Tools.sdkManager.path.hasPrefix(Tools.homebrewSDK), !sdk.hasPrefix(Tools.homebrewSDK) {
            path.append(Tools.homebrewSDK + "/cmdline-tools/latest/bin")
        }
        lines.append("export PATH=\"\(path.joined(separator: ":")):$PATH\"")
        return lines.joined(separator: "\n")
    }
}

/// Writes TVDroid's JAVA_HOME, ANDROID_HOME and PATH into the shell startup file (~/.zshrc),
/// so that `sdkmanager`, `adb` and `emulator` work in every new Terminal window too.
enum ShellProfile {
    static let begin = "# >>> TVDroid >>>"
    static let end = "# <<< TVDroid <<<"

    static func block() -> String {
        "\(begin)\n# Added by TVDroid. Remove this block to undo.\n\(TerminalLauncher.environmentExports())\n\(end)\n"
    }

    static var isInstalled: Bool {
        ((try? String(contentsOf: UserShell.rcFile, encoding: .utf8)) ?? "").contains(begin)
    }

    /// Adds the block, or replaces the old TVDroid block.
    static func install() throws {
        guard UserShell.name != "fish" else {
            throw ShellError.failed("TVDroid can only edit zsh and bash startup files. Add these lines yourself:\n\(TerminalLauncher.environmentExports())")
        }
        // Edit the real file. Writing to a symlink (dotfiles in a git repo) would replace the link with a copy.
        let file = UserShell.rcFile.resolvingSymlinksInPath()
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let hadBlock = text.contains(begin)
        if let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) {
            var upper = stop.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            text.replaceSubrange(start.lowerBound..<upper, with: block())
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + block()
        }
        // Keep a backup of the original file: only before the first TVDroid block, so an update keeps it.
        if FileManager.default.fileExists(atPath: file.path), !hadBlock {
            let backup = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".tvdroid-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
