import Foundation

/// A virtual USB keyboard in the TV. All key presses go through it.
///
/// The emulator console accepts `event send EV_KEY` but the keys never reach Android on this
/// system image. SELinux also blocks direct writes to /dev/input. The Android `uinput` tool can
/// make a real input device, and adb's shell user may use it. One `uinput` process stays open,
/// so each key takes a few milliseconds.
final class VirtualKeyboard: @unchecked Sendable {
    static let shared = VirtualKeyboard()

    private let queue = DispatchQueue(label: "tvdroid.keyboard")
    private var process: Process?
    private var input: FileHandle?
    /// Keys that are down now. They are released when the TV window loses focus.
    private var pressed = Set<Int>()

    private init() {
        // A write to a closed pipe must not stop the app.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Public

    /// Presses and releases one key.
    func tap(_ code: Int, shift: Bool = false) {
        queue.async {
            var events: [Int] = []
            if shift { events += [1, Linux.leftShift, 1, 0, 0, 0] }
            events += [1, code, 1, 0, 0, 0, 1, code, 0, 0, 0, 0]
            if shift { events += [1, Linux.leftShift, 0, 0, 0, 0] }
            self.inject(events)
        }
    }

    /// Sends a key down or key up. Android makes the key repeat while it is down.
    func set(_ code: Int, down: Bool) {
        queue.async {
            if down { self.pressed.insert(code) } else { self.pressed.remove(code) }
            self.inject([1, code, down ? 1 : 0, 0, 0, 0])
        }
    }

    /// Releases all keys that are down, so that no key repeats forever.
    func releaseAll() {
        queue.async {
            guard !self.pressed.isEmpty else { return }
            let events = self.pressed.flatMap { [1, $0, 0, 0, 0, 0] }
            self.pressed.removeAll()
            self.inject(events)
        }
    }

    /// Types text into the focused field. Characters that are not on a US keyboard are skipped.
    func type(_ text: String) {
        for character in text {
            if let (code, shift) = Linux.key(for: character) { tap(code, shift: shift) }
        }
    }

    /// Closes the virtual keyboard. The next key makes a new one, for example after the TV restarts.
    func reset() {
        queue.async { self.stop() }
    }

    // MARK: - uinput process

    private func inject(_ events: [Int]) {
        guard ensureStarted() else { return }
        write(["id": 1, "command": "inject", "events": events])
    }

    private func ensureStarted() -> Bool {
        if process?.isRunning == true, input != nil { return true }
        stop()
        let process = Process()
        process.executableURL = Tools.adb
        process.arguments = ["-s", TVController.serial, "shell", "uinput", "-"]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        self.process = process
        self.input = pipe.fileHandleForWriting
        write([
            "id": 1, "command": "register", "name": "TVDroid Keyboard",
            "vid": 0x18d1, "pid": 0x4ee7, "bus": "usb",
            "configuration": [
                ["type": 100, "data": [1]],                              // UI_SET_EVBIT: EV_KEY
                ["type": 101, "data": Array(1...255) + [352, 353]],      // UI_SET_KEYBIT
            ],
        ])
        // Android needs a moment to add the new device. Keys sent before that are lost.
        write(["id": 1, "command": "delay", "duration": 400])
        return true
    }

    private func write(_ object: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { stop() }
    }

    private func stop() {
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        pressed.removeAll()
    }
}

/// Linux input key codes (linux/input-event-codes.h) and the Mac key codes that map to them.
enum Linux {
    static let leftShift = 42
    static let back = 158
    static let home = 172

    /// Mac virtual key code → Linux key code. Both name a key position, not a character.
    static let macKeys: [UInt16: Int] = [
        // Letters
        0: 30, 11: 48, 8: 46, 2: 32, 14: 18, 3: 33, 5: 34, 4: 35, 34: 23, 38: 36, 40: 37, 37: 38, 46: 50,
        45: 49, 31: 24, 35: 25, 12: 16, 15: 19, 1: 31, 17: 20, 32: 22, 9: 47, 13: 17, 7: 45, 16: 21, 6: 44,
        // Digits
        29: 11, 18: 2, 19: 3, 20: 4, 21: 5, 23: 6, 22: 7, 26: 8, 28: 9, 25: 10,
        // Symbols
        27: 12, 24: 13, 33: 26, 30: 27, 42: 43, 41: 39, 39: 40, 50: 41, 43: 51, 47: 52, 44: 53,
        // Editing and navigation
        36: 28, 76: 96, 48: 15, 49: 57, 51: 14, 117: 111, 115: 172, 119: 107, 116: 104, 121: 109,
        123: 105, 124: 106, 125: 108, 126: 103,
        // Function keys
        122: 59, 120: 60, 99: 61, 118: 62, 96: 63, 97: 64, 98: 65, 100: 66, 101: 67, 109: 68, 103: 87, 111: 88,
        // Keypad
        82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72, 92: 73,
        65: 83, 67: 55, 69: 78, 75: 98, 78: 74, 81: 117,
        // Modifiers (Command and Option stay on the Mac)
        56: 42, 60: 54, 59: 29, 62: 97, 57: 58,
        // Esc is Back on a TV remote
        53: 158,
    ]

    /// Character → Linux key code on a US keyboard, and whether Shift is needed.
    static func key(for character: Character) -> (Int, Bool)? {
        if let code = plain[character] { return (code, false) }
        if let code = shifted[character] { return (code, true) }
        if character.isUppercase, let code = plain[Character(character.lowercased())] { return (code, true) }
        return nil
    }

    private static let plain: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (characters, codes) in [("1234567890", 2...11), ("qwertyuiop", 16...25), ("asdfghjkl", 30...38), ("zxcvbnm", 44...50)] {
            for (character, code) in zip(characters, codes) { map[character] = code }
        }
        let symbols: [Character: Int] = ["-": 12, "=": 13, "[": 26, "]": 27, ";": 39, "'": 40, "`": 41, "\\": 43,
                                         ",": 51, ".": 52, "/": 53, " ": 57, "\t": 15, "\n": 28]
        return map.merging(symbols) { a, _ in a }
    }()

    private static let shifted: [Character: Int] = [
        "!": 2, "@": 3, "#": 4, "$": 5, "%": 6, "^": 7, "&": 8, "*": 9, "(": 10, ")": 11, "_": 12, "+": 13,
        "{": 26, "}": 27, ":": 39, "\"": 40, "~": 41, "|": 43, "<": 51, ">": 52, "?": 53,
    ]
}
