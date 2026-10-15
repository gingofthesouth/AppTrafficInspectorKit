import Foundation
import Network

/// Minimal HTTP/1.1 server on 127.0.0.1 used to exercise TrafficURLProtocol's real forwarding path.
/// Supports Content-Length and chunked request bodies; replies with a fixed response and closes the connection.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct ReceivedRequest {
        let method: String
        let path: String
        let headers: [String: String]  // lowercased names
        let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let lock = NSLock()
    private var _requests: [ReceivedRequest] = []
    private let responseBody: Data
    private let responseContentType: String
    private(set) var port: UInt16 = 0

    init(responseBody: Data = Data("ok".utf8), responseContentType: String = "text/plain") throws {
        self.responseBody = responseBody
        self.responseContentType = responseContentType
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func requests() -> [ReceivedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func request(path: String) -> ReceivedRequest? {
        requests().last { $0.path == path }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.lock(); self._requests.append(request); self.lock.unlock()
                self.respond(conn)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(responseContentType)\r\n"
        head += "Content-Length: \(responseBody.count)\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + responseBody, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Returns a complete request if `buffer` contains one, otherwise nil.
    static func parse(_ buffer: Data) -> ReceivedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let rest = Data(buffer[headerEnd.upperBound...])
        let body: Data
        if let lengthString = headers["content-length"], let length = Int(lengthString) {
            guard rest.count >= length else { return nil }
            body = rest.prefix(length)
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(rest) else { return nil }
            body = decoded
        } else {
            body = Data()
        }
        return ReceivedRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return out }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            out.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
