import Foundation
import Testing
@testable import AppTrafficInspectorKit

/// Verifies request bodies (including upload-task bodies and streamed bodies) are both forwarded
/// to the server intact and recorded intact, and that cookies the forwarding session sends are recorded.
@Suite("Upload capture", .serialized)
struct UploadCaptureTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        func set() { lock.lock(); _value = true; lock.unlock() }
    }

    private static func imageLikePayload(byteCount: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var generator = SystemRandomNumberGenerator()
        data.append(contentsOf: (0..<(byteCount - data.count)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return data
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrafficURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeRequest(_ url: URL, contentType: String = "image/png") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func recordedStart(_ sink: RecordingSink, url: URL) -> (headers: [String: String], body: Data?)? {
        for event in sink.snapshot() where event.url == url {
            if case let .start(_, headers, body) = event.kind { return (headers, body) }
        }
        return nil
    }

    private static func finished(_ sink: RecordingSink, url: URL) -> Bool {
        sink.snapshot().contains { $0.url == url && ($0.kind == .finish || { if case .failure = $0.kind { return true } else { return false } }($0)) }
    }

    private static func waitFor(_ timeout: TimeInterval = 10, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func temporaryFile(containing data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    // MARK: - Real forwarding path

    private enum UploadKind: String, CaseIterable {
        case dataTaskHTTPBody, uploadFromData, uploadFromFile, asyncUploadFromData, asyncUploadFromFile
    }

    @MainActor @Test(arguments: UploadKind.allCases)
    private func uploadBody_isForwardedAndRecordedIntact(kind: UploadKind) throws {
        let server = try LoopbackHTTPServer()
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = nil
        let session = Self.makeSession()
        let payload = Self.imageLikePayload(byteCount: 3 * 1024 * 1024 + 17)
        let path = "/\(kind.rawValue)-\(UUID().uuidString)"
        let url = server.baseURL.appendingPathComponent(String(path.dropFirst()))
        var request = Self.makeRequest(url)
        let file = try Self.temporaryFile(containing: payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let done = Flag()

        switch kind {
        case .dataTaskHTTPBody:
            request.httpBody = payload
            session.dataTask(with: request) { _, _, _ in done.set() }.resume()
        case .uploadFromData:
            session.uploadTask(with: request, from: payload) { _, _, _ in done.set() }.resume()
        case .uploadFromFile:
            session.uploadTask(with: request, fromFile: file) { _, _, _ in done.set() }.resume()
        case .asyncUploadFromData:
            let req = request
            Task.detached { _ = try? await session.upload(for: req, from: payload); done.set() }
        case .asyncUploadFromFile:
            let req = request
            Task.detached { _ = try? await session.upload(for: req, fromFile: file); done.set() }
        }

        Self.waitFor { done.value && Self.finished(sink, url: url) }

        let received = try #require(server.request(path: path), "Server should receive the upload")
        #expect(received.method == "POST")
        #expect(received.body == payload, "Server must receive the full body")
        #expect(received.headers["content-type"] == "image/png")

        let recorded = try #require(Self.recordedStart(sink, url: url))
        #expect(recorded.body == payload, "Recorded body must match the uploaded bytes")
        #expect(recorded.headers["Content-Type"] == "image/png")
    }

    @MainActor @Test
    func slowProducerStreamBody_isForwardedAndRecordedIntact() throws {
        let server = try LoopbackHTTPServer()
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = nil
        let session = Self.makeSession()
        let chunks = (0..<5).map { Data(repeating: UInt8($0 + 1), count: 32 * 1024) }
        let expected = chunks.reduce(Data(), +)
        let path = "/stream-\(UUID().uuidString)"
        let url = server.baseURL.appendingPathComponent(String(path.dropFirst()))

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 8 * 1024, inputStream: &input, outputStream: &output)
        nonisolated(unsafe) let producerOutput = try #require(output)
        let producer = Thread {
            producerOutput.open()
            for chunk in chunks {
                Thread.sleep(forTimeInterval: 0.05)
                chunk.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < chunk.count {
                        let written = producerOutput.write(raw.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: chunk.count - offset)
                        if written <= 0 { return }
                        offset += written
                    }
                }
            }
            producerOutput.close()
        }

        var request = Self.makeRequest(url, contentType: "application/octet-stream")
        request.httpBodyStream = input
        let done = Flag()
        session.dataTask(with: request) { _, _, _ in done.set() }.resume()
        producer.start()

        Self.waitFor { done.value && Self.finished(sink, url: url) }

        let received = try #require(server.request(path: path))
        #expect(received.body == expected, "Server must receive the whole streamed body")
        let recorded = try #require(Self.recordedStart(sink, url: url))
        #expect(recorded.body == expected, "Recorded body must contain the whole stream")
    }

    // MARK: - Cookies

    @MainActor @Test
    func cookiesFromSharedStorage_areRecordedAndMatchWhatServerReceives() throws {
        let server = try LoopbackHTTPServer()
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        TrafficURLProtocol.maxBodyBytes = nil
        let session = Self.makeSession()
        let path = "/cookies-\(UUID().uuidString)"
        let url = server.baseURL.appendingPathComponent(String(path.dropFirst()))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: path, .name: "sid", .value: "abc123", .originURL: url,
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        let done = Flag()
        session.dataTask(with: URLRequest(url: url)) { _, _, _ in done.set() }.resume()
        Self.waitFor { done.value && Self.finished(sink, url: url) }

        let received = try #require(server.request(path: path))
        #expect(received.headers["cookie"] == "sid=abc123")
        let recorded = try #require(Self.recordedStart(sink, url: url))
        #expect(recorded.headers["Cookie"] == "sid=abc123")
    }

    @MainActor @Test
    func explicitCookieHeader_isPreserved() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        let session = Self.makeSession()
        let host = "cookie-\(UUID().uuidString.lowercased()).test"
        let url = URL(string: "mock://\(host)/explicit")!
        let cookie = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "sid", .value: "fromStorage", .originURL: url,
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        var request = URLRequest(url: url)
        request.setValue("manual=1", forHTTPHeaderField: "Cookie")
        session.dataTask(with: request) { _, _, _ in }.resume()
        Self.waitFor { Self.finished(sink, url: url) }

        let recorded = try #require(Self.recordedStart(sink, url: url))
        #expect(recorded.headers["Cookie"] == "manual=1")
    }

    @MainActor @Test
    func cookies_notRecorded_whenRequestOptsOut() throws {
        let sink = RecordingSink()
        TrafficURLProtocol.eventSink = sink
        let session = Self.makeSession()
        let host = "cookie-\(UUID().uuidString.lowercased()).test"
        let url = URL(string: "mock://\(host)/optout")!
        let cookie = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "sid", .value: "fromStorage", .originURL: url,
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        session.dataTask(with: request) { _, _, _ in }.resume()
        Self.waitFor { Self.finished(sink, url: url) }

        let recorded = try #require(Self.recordedStart(sink, url: url))
        #expect(recorded.headers["Cookie"] == nil)
    }
}
