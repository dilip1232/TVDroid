import Foundation
import Network

/// Sends input to the emulator. Touch goes through the console (telnet) port.
/// Keys and text go through `VirtualKeyboard`.
/// `adb shell input` starts a new Java process for each key and is too slow for a remote.
final class EmulatorConsole: @unchecked Sendable {
    /// Remote keys and their Linux input key codes.
    enum Key: String, CaseIterable {
        case up, down, left, right, ok, back, home, menu, search
        case playpause, play, pause, rewind, forward, previous, next
        case volup, voldown, mute, backspace

        /// Linux input key code. See linux/input-event-codes.h.
        var code: Int {
            switch self {
            case .up: return 103
            case .down: return 108
            case .left: return 105
            case .right: return 106
            case .ok: return 353        // KEY_SELECT → DPAD_CENTER
            case .back: return Linux.back
            case .home: return Linux.home
            case .menu: return 139
            case .search: return 217
            case .playpause: return 164
            case .play: return 200      // KEY_PLAYCD
            case .pause: return 201     // KEY_PAUSECD
            case .rewind: return 168
            case .forward: return 208
            case .previous: return 165
            case .next: return 163
            case .volup: return 115
            case .voldown: return 114
            case .mute: return 113
            case .backspace: return 14
            }
        }
    }

    static let shared = EmulatorConsole(port: TVController.port)

    private let port: UInt16
    private let queue = DispatchQueue(label: "tvdroid.console")
    private var connection: NWConnection?
    private var ready = false
    private var pending: [String] = []

    init(port: Int) {
        self.port = UInt16(port)
    }

    // MARK: - Input

    /// Keys go through the virtual keyboard. Console key events do not reach Android.
    func press(_ key: Key) {
        VirtualKeyboard.shared.tap(key.code)
    }

    /// Types text into the focused field.
    @discardableResult
    func type(_ text: String) -> String {
        VirtualKeyboard.shared.type(text)
    }

    /// Touch at a point in TV screen pixels. `down` false lifts the finger.
    func touch(x: Int, y: Int, down: Bool) {
        send("event mouse \(x) \(y) 0 \(down ? 1 : 0)")
    }

    /// Closes the connection. The next command opens a new one.
    func reset() {
        VirtualKeyboard.shared.reset()
        VirtualMouse.shared.reset()
        VirtualGamepad.shared.reset()
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.ready = false
            self.pending.removeAll()
        }
    }

    // MARK: - Connection

    private func send(_ command: String) {
        queue.async {
            if self.ready, let connection = self.connection {
                connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
            } else {
                self.pending.append(command)
                if self.pending.count > 200 { self.pending.removeFirst(self.pending.count - 200) }
                self.connectIfNeeded()
            }
        }
    }

    private func connectIfNeeded() {
        guard connection == nil else { return }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.authenticate(connection)
            case .failed, .cancelled:
                self.queue.async {
                    if self.connection === connection {
                        self.connection = nil
                        self.ready = false
                    }
                }
            default:
                break
            }
        }
        receiveLoop(connection)
        connection.start(queue: queue)
    }

    private func authenticate(_ connection: NWConnection) {
        let tokenURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".emulator_console_auth_token")
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        connection.send(content: Data("auth \(token)\r\n".utf8), completion: .contentProcessed { _ in })
        ready = true
        let queued = pending
        pending.removeAll()
        for command in queued {
            connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
        }
    }

    /// Reads and drops the console replies, so the socket buffer never fills.
    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self?.receiveLoop(connection)
        }
    }
}
