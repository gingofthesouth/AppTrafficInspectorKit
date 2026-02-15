//
// AppTrafficInspectorKit
// Copyright 2025 Ernest Cunningham
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This project is inspired by and based on the architecture of Bagel
// (https://github.com/yagiz/Bagel), Copyright (c) 2018 Bagel.
//

import Foundation

public enum TrafficEventKind: Equatable {
    case start
    case response(URLResponse)
    case data(Data)
    case finish
}

public struct TrafficEvent: Equatable, @unchecked Sendable {
    /// Unique id for this request lifecycle. When set, the inspector keys by this so concurrent requests to the same URL do not overwrite each other.
    public let requestId: UUID?
    public let url: URL
    public let kind: TrafficEventKind
    /// The underlying URLRequest, when available (e.g. for .start). Used to record method, headers, and body.
    public let request: URLRequest?

    public init(requestId: UUID? = nil, url: URL, kind: TrafficEventKind, request: URLRequest? = nil) {
        self.requestId = requestId
        self.url = url
        self.kind = kind
        self.request = request
    }

    public static func == (lhs: TrafficEvent, rhs: TrafficEvent) -> Bool {
        lhs.requestId == rhs.requestId && lhs.url == rhs.url && lhs.kind == rhs.kind
    }
}

@MainActor
public protocol TrafficURLProtocolEventSink: AnyObject {
    func record(_ event: TrafficEvent)
}

public final class TrafficURLProtocol: URLProtocol {
    nonisolated(unsafe) public static weak var eventSink: TrafficURLProtocolEventSink?
    nonisolated(unsafe) public static var maxBodyBytes: Int?

    /// Forwarding session: lock-protected. Set by TrafficInspector when it creates its lazy session.
    private static let forwardingSessionLock = NSLock()
    nonisolated(unsafe) private static var _forwardingSession: URLSession?

    static func setForwardingSession(_ session: URLSession?) {
        forwardingSessionLock.lock()
        _forwardingSession = session
        forwardingSessionLock.unlock()
    }

    /// Returns the forwarding session. Lock-protected; URLSession is thread-safe once created.
    private static func getForwardingSession() -> URLSession? {
        forwardingSessionLock.lock()
        let result = _forwardingSession
        forwardingSessionLock.unlock()
        return result
    }

    private static let activeForwardingLock = NSLock()
    /// Protected by activeForwardingLock; nonisolated(unsafe) because access is always under the lock.
    nonisolated(unsafe) private static var activeForwarding: [UUID: TrafficURLProtocol] = [:]

    private var receivedBytes: Int = 0
    private var forwardingTask: URLSessionDataTask?
    private var forwardingToken: UUID?

    public override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme else { return false }
        switch scheme.lowercased() {
        case "http", "https": return true
        case "mock": return true // For testing
        default: return false
        }
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let url = request.url else { return }

        switch url.scheme?.lowercased() {
        case "mock":
            startLoadingMock(url: url)
        case "http", "https":
            startLoadingReal(url: url)
        default:
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL, userInfo: nil))
        }
    }

    private func recordEvent(_ event: TrafficEvent) {
        DispatchQueue.main.async { Self.eventSink?.record(event) }
    }

    private func startLoadingMock(url: URL) {
        let requestId = UUID()
        let requestToRecord = request
        recordEvent(TrafficEvent(requestId: requestId, url: url, kind: .start, request: requestToRecord))

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        recordEvent(TrafficEvent(requestId: requestId, url: url, kind: .response(response)))

        let fullBody = Data([0x41, 0x42, 0x43, 0x44, 0x45])
        let limit = Self.maxBodyBytes ?? fullBody.count
        let body = fullBody.prefix(limit)
        receivedBytes += body.count
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
            recordEvent(TrafficEvent(requestId: requestId, url: url, kind: .data(Data(body))))
        }

        client?.urlProtocolDidFinishLoading(self)
        recordEvent(TrafficEvent(requestId: requestId, url: url, kind: .finish))
    }

    private func startLoadingReal(url: URL) {
        let requestId = UUID()
        guard let session = Self.getForwardingSession() else {
            let message = "Forwarding session not available. Ensure TrafficInspector is created on the main thread so the forwarding session is set."
            DevLogger.logError(message: message)
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: message]))
            recordEvent(TrafficEvent(requestId: requestId, url: url, kind: .finish))
            return
        }

        let requestToRecord = request
        recordEvent(TrafficEvent(requestId: requestId, url: url, kind: .start, request: requestToRecord))

        Self.activeForwardingLock.lock()
        Self.activeForwarding[requestId] = self
        Self.activeForwardingLock.unlock()
        forwardingToken = requestId

        let task = session.dataTask(with: request) { [requestId] data, response, error in
            Self.activeForwardingLock.lock()
            let proto = Self.activeForwarding.removeValue(forKey: requestId)
            Self.activeForwardingLock.unlock()

            guard let proto else { return }
            if let error = error {
                DevLogger.logError(error)
                proto.client?.urlProtocol(proto, didFailWithError: error)
                DispatchQueue.main.async {
                    Self.eventSink?.record(TrafficEvent(requestId: requestId, url: url, kind: .finish))
                }
                return
            }
            if let response = response {
                proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                DispatchQueue.main.async {
                    Self.eventSink?.record(TrafficEvent(requestId: requestId, url: url, kind: .response(response)))
                }
            }
            if let data = data, !data.isEmpty {
                let limit = Self.maxBodyBytes ?? Int.max
                let toSend = data.prefix(limit)
                proto.client?.urlProtocol(proto, didLoad: Data(toSend))
                DispatchQueue.main.async {
                    Self.eventSink?.record(TrafficEvent(requestId: requestId, url: url, kind: .data(Data(toSend))))
                }
            }
            proto.client?.urlProtocolDidFinishLoading(proto)
            DispatchQueue.main.async {
                Self.eventSink?.record(TrafficEvent(requestId: requestId, url: url, kind: .finish))
            }
        }
        forwardingTask = task
        task.resume()
    }

    public override func stopLoading() {
        if let token = forwardingToken {
            Self.activeForwardingLock.lock()
            Self.activeForwarding.removeValue(forKey: token)
            Self.activeForwardingLock.unlock()
            forwardingToken = nil

            // Record .finish so TrafficInspector removes the accumulator and avoids a leak.
            if let url = request.url {
                recordEvent(TrafficEvent(requestId: token, url: url, kind: .finish))
            }
        }
        forwardingTask?.cancel()
        forwardingTask = nil
    }
}
