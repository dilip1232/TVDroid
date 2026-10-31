import AppKit
import CoreImage
import Foundation
import Network
import os
import SystemConfiguration

/// A small web server for the phone remote.
/// Open the address on any phone on the same Wi-Fi. A secret token in the URL stops other people on the network.
@MainActor
final class RemoteServer: ObservableObject {
    nonisolated static let port: UInt16 = 8765

    @Published private(set) var url: URL?
    /// The same page by the Mac's network name (name.local). It keeps working when the address changes.
    /// iPhones open it; some Android phones cannot.
    @Published private(set) var lastingURL: URL?
    @Published private(set) var isRunning = false

    /// Read by connections on other threads: the phone sees "TV is off" instead of keys that go nowhere.
    nonisolated static let isTVOn = OSAllocatedUnfairLock(initialState: false)

    private var listener: NWListener?
    private var retry: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let token = OSAllocatedUnfairLock(initialState: RemoteServer.savedToken())

    private static func savedToken() -> String {
        if let saved = UserDefaults.standard.string(forKey: "remoteToken") { return saved }
        return newToken()
    }

    private static func newToken() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let new = String((0..<10).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(new, forKey: "remoteToken")
        return new
    }

    init() {
        start()
        // A new Wi-Fi network gives the Mac a new address. Keep the QR code current.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshURL() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// Makes a new address. Phones that have the old one can no longer control the TV.
    func newLink() {
        let new = Self.newToken()
        token.withLock { $0 = new }
        refreshURL()
    }

    func start() {
        guard listener == nil else { return }
        retry?.cancel()
        retry = nil
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "TVDroid Remote", type: "_http._tcp")
            listener.newConnectionHandler = { [token] connection in
                let token = token.withLock { $0 }
                RemoteConnection(connection: connection, token: token, lastingURL: Self.lastingAddress(token: token)).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.isRunning = true; self.refreshURL()
                    case .failed, .cancelled:
                        self.isRunning = false
                        self.listener = nil
                        self.scheduleRetry()
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            NSLog("TVDroid: remote server failed: \(error)")
            scheduleRetry()
        }
    }

    /// The port can be busy for a while (another app, or the Mac just woke up). Try again.
    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.retry = nil
            self?.start()
        }
    }

    /// Updates the address. Call this when the Wi-Fi network changes.
    func refreshURL() {
        let token = token.withLock { $0 }
        lastingURL = Self.lastingAddress(token: token).flatMap(URL.init(string:))
        guard let ip = Self.lanAddress() else { url = nil; return }
        url = URL(string: "http://\(ip):\(Self.port)/r/\(token)")
    }

    /// "http://Name.local:8765/r/token", from the Local Hostname in System Settings ▸ Sharing.
    nonisolated static func lastingAddress(token: String) -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return "http://\(name).local:\(port)/r/\(token)"
    }

    /// A QR code image for the remote address.
    func qrCode(size: CGFloat) -> NSImage? {
        guard let url, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// A private IPv4 address on Wi-Fi or Ethernet. A home network address (192.168, 10, 172.16–31)
    /// comes before others, and en0 before en1 before en10. Self-assigned 169.254 addresses are skipped.
    private static func lanAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var found: [(String, String)] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            found.append((name, ip))
        }
        func isPrivate(_ ip: String) -> Bool {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
        }
        func index(_ name: String) -> Int { Int(name.dropFirst(2)) ?? Int.max }
        return found.min { a, b in
            isPrivate(a.1) != isPrivate(b.1) ? isPrivate(a.1) : index(a.0) < index(b.0)
        }?.1
    }
}

/// One HTTP request and response. Each request uses a new connection.
private final class RemoteConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let lastingURL: String?
    private var buffer = Data()

    init(connection: NWConnection, token: String, lastingURL: String?) {
        self.connection = connection
        self.token = token
        self.lastingURL = lastingURL
    }

    func start() {
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                respond(to: request)
            } else if isComplete || error != nil || buffer.count > 256 * 1024 {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    private func respond(to request: HTTPRequest) {
        let prefix = "/r/\(token)"
        guard request.path == prefix || request.path.hasPrefix(prefix + "/") else {
            return reply(404, "text/plain", Data("Not found".utf8))
        }
        let route = String(request.path.dropFirst(prefix.count))

        switch (request.method, route) {
        case ("GET", ""), ("GET", "/"):
            let page = RemotePage.html.replacingOccurrences(of: "__LASTING_URL__", with: lastingURL ?? "")
            reply(200, "text/html; charset=utf-8", Data(page.utf8))
        case ("GET", "/ping"):
            // The page shows "TV is off" for 409.
            reply(RemoteServer.isTVOn.withLock { $0 } ? 204 : 409, "text/plain", Data())
        case ("POST", _) where !RemoteServer.isTVOn.withLock({ $0 }):
            reply(409, "text/plain", Data("The TV is off".utf8))
        case ("POST", let r) where r.hasPrefix("/key/"):
            let name = String(r.dropFirst("/key/".count))
            guard let key = EmulatorConsole.Key(rawValue: name) else { return reply(400, "text/plain", Data()) }
            EmulatorConsole.shared.press(key)
            reply(204, "text/plain", Data())
        case ("POST", "/mouse"):
            // Trackpad events, one per line: "m dx dy" (move), "s v h" (scroll), "c left" (click),
            // "d left" / "u left" (button down / up, for drag).
            Self.handleMouse(String(decoding: request.body, as: UTF8.self))
            reply(204, "text/plain", Data())
        case ("POST", "/text"):
            // The page shows the characters that a US keyboard cannot type.
            let skipped = EmulatorConsole.shared.type(String(decoding: request.body, as: UTF8.self))
            reply(skipped.isEmpty ? 204 : 200, "text/plain; charset=utf-8", Data(skipped.utf8))
        default:
            reply(404, "text/plain", Data("Not found".utf8))
        }
    }

    private static func handleMouse(_ body: String) {
        let mouse = VirtualMouse.shared
        var dx = 0, dy = 0, sv = 0, sh = 0
        func flush() {
            mouse.move(dx: dx, dy: dy); mouse.scroll(vertical: sv, horizontal: sh)
            dx = 0; dy = 0; sv = 0; sh = 0
        }
        for line in body.split(separator: "\n").prefix(500) {
            let parts = line.split(separator: " ")
            guard let op = parts.first else { continue }
            let numbers = parts.dropFirst().compactMap { Int($0) }.map { max(-2000, min(2000, $0)) }
            let button = parts.count > 1 ? VirtualMouse.Button(rawValue: String(parts[1])) : nil
            switch op {
            case "m" where numbers.count == 2: dx += numbers[0]; dy += numbers[1]
            case "s" where numbers.count == 2: sv += numbers[0]; sh += numbers[1]
            case "c": flush(); if let button { mouse.click(button) }
            case "d": flush(); if let button { mouse.set(button, down: true) }
            case "u": flush(); if let button { mouse.set(button, down: false) }
            default: break
            }
        }
        flush()
    }

    private func reply(_ status: Int, _ type: String, _ body: Data) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found", 409: "Conflict"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// Returns nil until the full request (headers and body) has arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1].split(separator: "?").first ?? "")
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        body = data[bodyStart..<(bodyStart + length)]
    }
}
