import AppKit
import CoreImage
import Foundation
import Network

/// A small web server for the phone remote.
/// Open the address on any phone on the same Wi-Fi. A secret token in the URL stops other people on the network.
@MainActor
final class RemoteServer: ObservableObject {
    static let port: UInt16 = 8765

    @Published private(set) var url: URL?
    @Published private(set) var isRunning = false

    private var listener: NWListener?
    private let token: String = {
        if let saved = UserDefaults.standard.string(forKey: "remoteToken") { return saved }
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let new = String((0..<10).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(new, forKey: "remoteToken")
        return new
    }()

    init() { start() }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "TVDroid Remote", type: "_http._tcp")
            listener.newConnectionHandler = { [token] connection in
                RemoteConnection(connection: connection, token: token).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.isRunning = true; self.refreshURL()
                    case .failed, .cancelled: self.isRunning = false; self.listener = nil
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            NSLog("TVDroid: remote server failed: \(error)")
        }
    }

    /// Updates the address. Call this when the Wi-Fi network changes.
    func refreshURL() {
        guard let ip = Self.lanAddress() else { url = nil; return }
        url = URL(string: "http://\(ip):\(Self.port)/r/\(token)")
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

    /// The first private IPv4 address on Wi-Fi or Ethernet.
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
            found.append((name, String(cString: host)))
        }
        return found.sorted { $0.0 < $1.0 }.first?.1
    }
}

/// One HTTP request and response. Each request uses a new connection.
private final class RemoteConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private var buffer = Data()

    init(connection: NWConnection, token: String) {
        self.connection = connection
        self.token = token
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
            reply(200, "text/html; charset=utf-8", Data(RemotePage.html.utf8))
        case ("POST", let r) where r.hasPrefix("/key/"):
            let name = String(r.dropFirst("/key/".count))
            guard let key = EmulatorConsole.Key(rawValue: name) else { return reply(400, "text/plain", Data()) }
            EmulatorConsole.shared.press(key)
            reply(204, "text/plain", Data())
        case ("POST", "/text"):
            EmulatorConsole.shared.type(String(decoding: request.body, as: UTF8.self))
            reply(204, "text/plain", Data())
        default:
            reply(404, "text/plain", Data("Not found".utf8))
        }
    }

    private func reply(_ status: Int, _ type: String, _ body: Data) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
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
